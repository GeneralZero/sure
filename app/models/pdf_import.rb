class PdfImport < Import
  has_one_attached :pdf_file, dependent: :purge_later

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true
  validate :account_statement_matches_import

  class << self
    # PdfImport's importing status doubles as a processing claim: the AI
    # extraction claim from process_with_ai_later (no rows yet) or a regular
    # publish (rows being written). A lost job leaves the claim held forever —
    # ProcessPdfJob's own reclaim only runs when the job is redelivered.
    # Which claim died is observable from the data: no rows attached → the AI
    # claim, reclaim to pending so the user can re-trigger; rows attached →
    # the publish died after import!'s commit, so finalize as complete
    # (pending would let the user publish the same extracted rows again —
    # PdfImport#import! always builds new transactions). Stuck reverts go to
    # revert_failed like every other import, keeping the retry path exposed.
    def clean
      where(status: [ :importing, :reverting ])
        .where("updated_at < ?", Import::STUCK_AFTER.ago)
        .includes(:family)
        .find_each do |pdf_import|
          reap_stuck!(pdf_import)
        rescue => e
          # One bad record must not abort the sweep for the rest.
          Rails.logger.error("PdfImport.clean failed for #{pdf_import.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) { |scope| scope.set_tags(record_type: name, record_id: pdf_import.id) } if defined?(Sentry)
        end
    end

    def reap_stuck!(pdf_import)
      needs_sync = false
      # Read before the lock — see Import.reap_stuck!.
      family = pdf_import.family

      pdf_import.with_lock do
        next unless pdf_import.reapable_since?(Import::STUCK_AFTER.ago)

        previous_status = pdf_import.status
        if previous_status == "reverting"
          pdf_import.update!(status: :revert_failed, error: Import.interrupted_error_message)
        elsif pdf_import.data_committed?
          pdf_import.update!(status: :complete, error: nil)
          needs_sync = true
        else
          pdf_import.update!(status: :pending)
        end

        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "Reclaimed PdfImport stuck in #{previous_status} for over #{Import::STUCK_AFTER.inspect} (→ #{pdf_import.status})",
          source: name,
          family: family,
          metadata: { record_type: name, record_id: pdf_import.id, previous_status: previous_status, new_status: pdf_import.status }
        )
      end

      # Outside the row lock — see Import.reap_stuck!.
      family.sync_later if needs_sync
    end

    def create_from_upload!(family:, file:, user:)
      statement = AccountStatement.create_from_prepared_upload!(
        family: family,
        account: nil,
        prepared_upload: AccountStatement.prepare_upload!(file)
      )

      create_from_statement!(statement: statement)
    rescue AccountStatement::DuplicateUploadError => e
      raise unless e.statement.manageable_by?(user)

      create_from_statement!(statement: e.statement)
    end

    def create_from_statement!(statement:)
      reusable_import = statement.latest_reusable_pdf_import
      return reusable_import if reusable_import &&
                                reusable_import.account_id == statement.account_id &&
                                reusable_import.date_format == statement.family.date_format

      create!(family: statement.family, account: statement.account, account_statement: statement, date_format: statement.family.date_format, status: :pending)
    end
  end

  # A PdfImport's importing status is a processing claim (AI extraction or
  # publish). Release a lost claim back to pending so the user can re-trigger
  # processing, mirroring ProcessPdfJob's own reclaim; lost reverts keep the
  # base revert_failed behavior.
  def force_fail!(error_message = Import.lost_error_message)
    return super if reverting?

    with_lock do
      return false unless presumed_lost?

      update!(status: :pending)
    end

    true
  end

  def import!
    raise "Account required for PDF import" unless account.present?

    transaction do
      mappings.each(&:create_mappable!)

      # Rows were already filtered against existing records when they were
      # generated, but a provider sync can land in between, so check again here
      # the way TransactionImport#import! does.
      adapter = Account::ProviderImportAdapter.new(account)
      # Entries this statement already consumed during row generation are spoken
      # for. Without excluding them, a statement carrying two same-amount
      # transactions where the account held only one would re-match the surviving
      # row against that same entry and silently drop a genuinely new
      # transaction. Newly synced entries are still caught, because only the
      # already-reconciled ones are excluded.
      claimed = reconciled_entries.pluck(:id)
      reconciled_now = []
      reconciled_at = Time.current

      new_transactions = rows.filter_map do |row|
        if (existing = already_recorded_entry(adapter, row, claimed))
          claimed << existing.id
          reconciled_now << existing
          next
        end

        label = investment_activity_label_for(row)

        Transaction.new(
          # A contribution is a transfer into the account, not a categorizable
          # expense/income — the dedicated category and `investment_contribution`
          # kind are what provider sync sets for the same label (see
          # Account::ProviderImportAdapter#apply_entry), and what downstream
          # budget/transfer accounting keys off. Without them a PDF-imported
          # contribution reads as an ordinary transaction under whatever
          # category the AI happened to extract.
          category: label == "Contribution" ? account.family.investment_contributions_category : mappings.categories.mappable_for(row.category),
          investment_activity_label: label,
          kind: label == "Contribution" ? :investment_contribution : :standard,
          entry: Entry.new(
            account: account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row.currency,
            notes: row.notes,
            import: self,
            import_locked: true,
            # Born reconciled: the statement being imported is the evidence.
            # Set by id rather than association so activerecord-import writes the
            # column directly on the recursive insert.
            reconciled_at: reconciled_at,
            reconciled_by_statement_id: account_statement&.id
          )
        )
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
      reconcile_entries!(reconciled_now, at: reconciled_at)
      backfill_opening_balance!
    end
  end

  # Re-targeting is destructive: it releases the statement's evidence on the
  # account being left and rebuilds the rows from scratch. Returns false rather
  # than doing any of that when the import is no longer re-targetable, so a
  # back-button or replayed PATCH cannot unwind a published import.
  def assign_account!(account)
    with_lock do
      return false unless reassignable?

      previous_account_id = account_id
      update!(account: account)
      # A statement with no extracted rows (e.g. an investment statement with
      # no cash activity that period) never reaches import!, which is where
      # this normally runs -- without it here too, picking an account for one
      # of these never backfills the opening balance its own extracted data
      # already has.
      backfill_opening_balance!

      if (statement = account_statement)
        statement.lock!
        statement.link_to_account!(account) if statement.account_id != account.id
      end

      next true if previous_account_id == account.id

      # Matching is per-account, so anything reconciled against the old account
      # is no longer evidence-backed, and the rows have to be judged again.
      release_reconciliations!(previous_account_id)
      if has_extracted_transactions?
        generate_rows_from_extracted_data
        sync_mappings
        refresh_status_after_regeneration!
      end

      true
    end
  end

  # A published import's entries already live in the account it was published
  # to, and a running job owns the record while it is importing or reverting.
  # An import that reconciled every line is still re-targetable: it is complete
  # but committed nothing of its own, and the user may well have picked the
  # wrong account.
  def reassignable?
    !data_committed? && !importing? && !reverting?
  end

  def pdf_uploaded?
    statement_backed? || pdf_file.attached?
  end

  def ai_processed?
    ai_summary.present?
  end

  def process_with_ai_later
    return false unless with_lock { pending? && !ai_processed? && rows_count.zero? && pdf_uploaded? && update!(status: :importing) }

    begin
      ProcessPdfJob.perform_later(self)
      true
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue PDF processing for import #{id}: #{e.class.name} - #{e.message}")
      reload.with_lock { update!(status: :pending) }
      false
    end
  end

  def process_with_ai
    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # process_pdf (PR #1985).
    provider = Provider::Registry.preferred_llm_provider
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_not_configured") unless provider
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_no_pdf_support") unless provider.supports_pdf_processing?

    response = provider.process_pdf(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise Provider::Error, error_message
    end

    result = response.data
    update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def extract_transactions
    return unless statement_with_transactions?

    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # extract_bank_statement (PR #1985).
    provider = Provider::Registry.preferred_llm_provider
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_not_configured") unless provider

    # Investment statements get the cash-only extractor (dividends, interest,
    # fees, contributions/withdrawals) — see
    # Provider::Openai::InvestmentStatementExtractor's header comment for why
    # buy/sell trade extraction is deliberately out of scope for now.
    response = if investment_statement?
      provider.extract_investment_statement(
        pdf_content: pdf_file_content,
        family: family
      )
    else
      provider.extract_bank_statement(
        pdf_content: pdf_file_content,
        family: family
      )
    end

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise Provider::Error, error_message
    end

    # BankStatementExtractor returns symbol keys, but every reader here (and in
    # generate_rows_from_extracted_data) digs with strings. jsonb keeps the hash
    # exactly as assigned until the record is reloaded, so without this the
    # in-memory read comes back empty and the import produces no rows at all.
    data = response.data.deep_stringify_keys
    update!(extracted_data: data)
    data
  end

  def bank_statement?
    document_type == "bank_statement"
  end

  def investment_statement?
    document_type == "investment_statement"
  end

  def statement_with_transactions?
    document_type.in?(%w[bank_statement credit_card_statement investment_statement])
  end

  def has_extracted_transactions?
    extracted_data.present? && extracted_data["transactions"].present?
  end

  def extracted_transactions
    filter_to_assigned_account(correct_self_referential_transfers(extracted_data&.dig("transactions") || []))
  end

  # Every distinct account_number seen across the extracted transactions, for a
  # statement that combines more than one account on a single document (a
  # checking + savings statement from the same bank, say). A single-account
  # statement -- the overwhelming common case -- has at most one.
  def detected_account_numbers
    nums = extracted_data&.dig("account_numbers").presence ||
      (extracted_data&.dig("transactions") || []).map { |t| t["account_number"] }.compact.uniq
    nums.presence || [ detected_account_number ].compact
  end

  def generate_rows_from_extracted_data
    transaction do
      # insert_all! below bypasses ActiveRecord, so the `rows` association is
      # never populated with what it wrote. Reload before destroying, or a second
      # call on the same in-memory record (assign_account! regenerating after
      # ProcessPdfJob already generated) clears a stale empty collection, deletes
      # nothing, and collides on (import_id, source_row_number).
      rows.reload.destroy_all

      unless has_extracted_transactions?
        update_column(:rows_count, 0)
        return
      end

      currency = account&.currency || family.currency
      candidates = extracted_transactions.map.with_index(1) do |txn, index|
        Import::Row.new(
          import: self,
          source_row_number: index,
          date: format_date_for_import(txn["date"]),
          amount: txn["amount"].to_s,
          name: txn["name"].to_s,
          category: txn["category"].to_s,
          notes: txn["notes"].to_s,
          currency: currency
        )
      end

      unmatched, matched_entries = partition_already_recorded(candidates)

      reconcile_entries!(matched_entries)

      mapped_rows = unmatched.map.with_index(1) do |row, index|
        {
          import_id: id,
          source_row_number: index,
          date: row.date,
          amount: row.amount,
          name: row.name,
          category: row.category,
          notes: row.notes,
          currency: row.currency
        }
      end

      Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
      # Drop the now-stale association cache so later reads (sync_mappings, the
      # view) see what was actually written.
      rows.reset
      update_column(:rows_count, mapped_rows.size)
    end
  end

  # Transactions this statement reconciled against records that already existed.
  # Derived from the statement link rather than stored, so it cannot go stale.
  def reconciled_entries
    return Entry.none if account_statement.blank?

    Entry.reconciled_by(account_statement)
  end

  # The half of reconciled_entries this import did not create -- transactions the
  # account already held when the statement arrived. Everything this import
  # creates is born reconciled too, so the two have to be told apart before
  # either count means anything.
  def already_recorded_entries
    reconciled_entries.where.not(id: entries.select(:id))
  end

  # The next three are memoized because the summary dialog and the review screen
  # each read them more than once, and every read is its own COUNT -- rendering
  # the dialog issued roughly fifteen queries for a static summary. They report
  # a finished outcome for display, so a value cached for the life of the
  # request is what callers want; anything re-judging the import recomputes from
  # the entries directly. (`||=` is safe here: 0 is truthy in Ruby.)
  def already_recorded_count
    @already_recorded_count ||= already_recorded_entries.count
  end

  def imported_count
    @imported_count ||= entries.count
  end

  # Rows still on offer. import! creates an entry per row and leaves the rows in
  # place as the record of what was published, so past that point rows_count is
  # a history, not a queue. Memoized mostly for data_committed?, which is two
  # more EXISTS queries every time it is asked.
  def awaiting_review_count
    @awaiting_review_count ||= data_committed? ? 0 : rows_count
  end

  # No query: extracted_data is already in memory.
  def extracted_count
    extracted_transactions.size
  end

  # Whether the statement described transactions the account already had. The
  # difference between "nothing to import" and "nothing was found".
  def reconciled_anything?
    already_recorded_count.positive?
  end

  # The real `status` enum (pending/importing/complete/failed/...) is too
  # coarse to show a user what is actually happening: `pending` means both
  # "just uploaded, AI hasn't even started" and "AI is done, rows are ready
  # for your review" (told apart today only by rows_count), and `importing`
  # means both "AI is actively reading the PDF" and "you clicked Publish and
  # your reviewed rows are being written to the ledger" - two completely
  # different operations with nothing in the DB directly distinguishing them
  # (only ai_processed? does, indirectly). This doesn't touch the real
  # `status` column or enum (too much other logic - validations, the reaper,
  # publishable?/revertable? - depends on its exact values); it only adds a
  # read-only, purely-derived view of the same state for display.
  #
  # :imported vs :complete doesn't exist in the real enum either: it alone
  # can't tell "I published this and it added transactions" apart from
  # "there was nothing to publish" - both just land on :complete, which
  # makes a statement still waiting on the user's review look no different
  # at a glance from one that's actually finished.
  def display_phase
    return :ready_for_review if pending? && rows_count > 0
    return :publishing if importing? && ai_processed?
    # Queued imports are `importing` too; only the one ProcessPdfJob is
    # actually reading carries processing_started_at.
    return :analyzing if importing? && processing_started_at.present?
    return :queued if importing?
    # ProcessPdfJob normally flips a zero-row, already-AI-processed record
    # straight to :complete in the same run that set ai_processed - a record
    # can only be seen sitting here if that final write never happened (job
    # died between the two updates, or something else re-armed processing on
    # an already-processed record without a job actually running). Showing
    # this as :queued would claim AI hasn't looked at it yet, which is false.
    return :stalled_after_processing if pending? && ai_processed? && rows_count.zero?
    return :queued if pending?
    # imported_count is entries this import itself created (already-matched/
    # reconciled rows create no new Entry - see Import#data_committed? and
    # #imported_count) - zero here means either a non-transaction document
    # (contract, tax form, ...) or a statement where every row matched
    # something already on file, not a failure.
    return :imported if complete? && imported_count.positive?
    return :complete if complete?

    status.to_sym
  end

  # Only meaningful in :queued - how many of this family's statements were
  # queued before this one and have not finished. Scoped to the family: the
  # job gate is app-wide, but another family's uploads are not this one's
  # business.
  def queued_behind_count
    return 0 unless display_phase == :queued

    family.imports.where(type: "PdfImport", status: :importing).where("created_at < ?", created_at).count
  end

  def send_next_steps_email(user)
    PdfImportMailer.with(
      user: user,
      pdf_import: self
    ).next_steps.deliver_later
  end

  def uploaded?
    pdf_uploaded?
  end

  def configured?
    ai_processed? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    account.present? && statement_with_transactions? && cleaned? && mappings.all?(&:valid?)
  end

  def cleaned_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def column_keys
    %i[date amount name category notes]
  end

  def requires_csv_workflow?
    false
  end

  def pdf_file_content
    return @pdf_file_content if defined?(@pdf_file_content)
    return @pdf_file_content = account_statement.original_file.download if statement_backed?

    @pdf_file_content = pdf_file.download if pdf_file.attached?
  end

  def pdf_filename
    return account_statement.filename if statement_backed?

    pdf_file.filename.to_s if pdf_file.attached?
  end

  # The statement's own identifying details, for the account picker: a
  # household with several accounts at the same institution (checking +
  # savings, or several brokerage accounts) can't be told apart by document
  # type alone, and the AI already extracts exactly what a human would check
  # the paper statement against.
  def detected_account_number
    extracted_data&.dig("account_number").presence
  end

  def detected_bank_name
    extracted_data&.dig("bank_name").presence
  end

  def detected_account_holder
    extracted_data&.dig("account_holder").presence
  end

  # A single display line built from whichever of the three details above are
  # actually present, so the view never has to reason about which subset the
  # AI managed to read off this particular statement. Nil when none are.
  def detected_account_summary
    parts = [ detected_bank_name, (detected_account_number && "····#{detected_account_number}"), detected_account_holder ].compact
    parts.join(" • ") if parts.any?
  end

  # Best-guess match between this statement and one of the family's own
  # accounts, from `candidates` (expected already scoped to what the current
  # user may pick from). Matched against the account's display name rather
  # than a dedicated field: nothing else reliably carries a linked or manual
  # account's last-4 digits, and this app's own naming convention already
  # puts them there (e.g. "Spending Account (6654)"). A false negative (no
  # suggestion) is the safe failure here -- the picker still works by hand --
  # so this never guesses without the statement's own digits to go on, and
  # never resolves multiple same-digit matches to one of them.
  def suggested_account(candidates)
    return nil if account.present?

    last4 = detected_account_number
    return nil if last4.blank?

    matches = candidates.select { |a| self.class.account_identifying_text(a).include?(last4) }
    matches.first if matches.one?
  end

  # Text to match a statement's detected last-4 digits against: the account's
  # own display name (the existing convention this app's naming puts them in,
  # e.g. "Spending Account (6654)"), plus -- when the account was created from
  # a SimpleFin connection -- the name SimpleFin itself reported. A user who
  # renames the account afterward (e.g. to "Ally Checking Account") loses the
  # digits the naming convention relies on, even though the underlying
  # connection's own name still has them.
  def self.account_identifying_text(account)
    return account.name.to_s if account.simplefin_account_id.blank?

    simplefin_name = SimplefinAccount.where(id: account.simplefin_account_id).pick(:name)
    [ account.name, simplefin_name ].compact.join(" ")
  end

  def statement_backed?
    account_statement&.original_file&.attached?
  end

  def required_column_keys
    %i[date amount]
  end

  def mapping_steps
    base = []
    # Only include CategoryMapping if rows have non-empty categories
    base << Import::CategoryMapping if rows.where.not(category: [ nil, "" ]).exists?
    # Note: PDF imports use direct account selection in the UI, not AccountMapping
    # AccountMapping is designed for CSV imports where rows have different account values
    base
  end

  private

    # A real statement can describe a transfer in a way that names the WRONG
    # side's own account by mistake (Ally's "WEB Funds Transfer ... from
    # Interest Checking account XXXXXX6654" sitting in the Checking section
    # itself is exactly this: XXXXXX6654 is Checking's own number, so a
    # transaction already tagged account_number XXXXXX6654 can't also be "from"
    # XXXXXX6654 -- one of the two is wrong). The extractor is asked to read
    # transfer_counterparty_account_number off the transaction's own text
    # without trying to reason about which account is correct (see e.g.
    # Provider::Openai::BankStatementExtractor); this is where that gets
    # resolved, deterministically rather than hoping the model guesses right.
    #
    # Only correctable when exactly two accounts are on the statement: with
    # exactly one alternative to the self-named number, that alternative must
    # be the transaction's real account. Three or more leaves genuine
    # ambiguity about which of the others is right, so those are left alone.
    def correct_self_referential_transfers(transactions)
      numbers = detected_account_numbers
      return transactions if numbers.size != 2

      transactions.map do |t|
        acct = t["account_number"]
        counterparty = t["transfer_counterparty_account_number"]
        next t if acct.blank? || counterparty.blank? || acct != counterparty

        other = numbers.find { |n| n != acct }
        other.present? ? t.merge("account_number" => other) : t
      end
    end

    # A combined statement (checking + savings from the same bank on one PDF,
    # say) extracts into a single flat transactions array, each row tagged
    # with the account_number of whichever section it came from (see
    # Provider::Openai::BankStatementExtractor). This import is bound to one
    # Sure account, so once more than one account_number shows up, every row
    # NOT belonging to this import's own account would otherwise get imported
    # here too -- the exact bug this guards against.
    #
    # Matched via .account_identifying_text (the same text #suggested_account
    # matches a statement to an account against). Falls back to importing
    # everything, unfiltered, whenever that match can't be made cleanly --
    # a single-account statement (account present but no digits, or only one
    # account_number detected across the whole document), or a multi-account
    # statement where this account's own number isn't among those detected
    # (silently dropping every row would be worse than the duplicate-risk this
    # exists to prevent).
    def filter_to_assigned_account(transactions)
      return transactions if account.blank?

      own_number = own_account_number
      return transactions if own_number.blank?

      transactions.select { |t| t["account_number"].blank? || t["account_number"] == own_number }
    end

    # This import's own account's number, among the statement's detected
    # account_numbers -- nil whenever there's nothing to disambiguate (a
    # single-account statement, or no account assigned yet) or the match
    # can't be made cleanly (this account's number isn't among those found).
    def own_account_number
      return nil if account.blank?

      numbers = detected_account_numbers
      return nil if numbers.size <= 1

      numbers.find { |n| self.class.account_identifying_text(account).include?(n) }
    end

    # The {opening_balance:, period_start:} this import's own account should
    # backfill from. A single-account statement just has the extraction's
    # top-level fields. A combined statement reports a separate entry per
    # account in "accounts" (see e.g. Provider::Openai::BankStatementExtractor)
    # -- this picks out the one matching this account's own number, falling
    # back to the top-level fields whenever that match can't be made (the same
    # cases #own_account_number itself returns nil for).
    def backfill_candidate
      fallback = {
        "opening_balance" => extracted_data&.dig("opening_balance"),
        "period_start" => extracted_data&.dig("period", "start_date")
      }

      number = own_account_number
      accounts = extracted_data&.dig("accounts")
      return fallback if number.blank? || accounts.blank?

      match = accounts.find { |a| a["account_number"] == number }
      return fallback if match.blank?

      { "opening_balance" => match["opening_balance"], "period_start" => match["period_start"] }
    end

    # A statement rarely covers the account's whole history -- it describes one
    # period, and whatever came before it is simply absent from what was
    # uploaded. Without an opening balance, every balance series/chart/return
    # calculation treats the day before the account's oldest entry as an
    # implicit $0 start, which is wrong whenever the real balance on that day
    # was anything else -- exactly the gap a statement's own stated opening
    # balance exists to fill (every extractor returns one; see e.g.
    # Provider::Openai::BankStatementExtractor).
    #
    # Prefers whichever statement goes back furthest: a later upload whose
    # period starts BEFORE the account's current opening anchor replaces it,
    # rather than being skipped just because an anchor already exists. Still
    # refuses whenever any real entry already predates this statement's
    # period -- that means this statement is not actually the earliest
    # evidence the account has, and overwriting the anchor with a guess would
    # silently contradict real data. Best-effort and never raises -- a
    # malformed or missing opening_balance/period on the extracted data leaves
    # the account exactly as it was; the user can still set one by hand from
    # the account settings.
    def backfill_opening_balance!
      candidate = backfill_candidate
      opening_balance = candidate["opening_balance"]
      period_start_str = candidate["period_start"]
      return if opening_balance.blank? || period_start_str.blank?

      period_start = Date.parse(period_start_str.to_s)
      anchor_date = period_start - 1.day
      return if account.has_opening_anchor? && anchor_date >= account.opening_anchor_date
      return if account.entries.where("date < ?", period_start).exists?

      Account::OpeningBalanceManager.new(account).set_opening_balance(
        balance: opening_balance,
        date: anchor_date
      )
    rescue ArgumentError, TypeError
      nil
    end

    # Investment-statement rows carry the AI's own activity classification in
    # row.category (Dividend/Interest/Fee/Contribution/Withdrawal/Other —
    # see Provider::Openai::InvestmentStatementExtractor's schema), a more
    # direct signal than pattern-matching the row's name text — prefer it
    # when it lines up with a real Transaction::ACTIVITY_LABELS value, and
    # fall back to Transaction.detect_activity_label (the same name-based
    # detection provider sync uses) otherwise. Bank/credit-card statement
    # rows never reach an investment account in practice, but the check is
    # by account type rather than document type so the label only ever
    # applies where it's actually meaningful.
    def investment_activity_label_for(row)
      return nil unless account.investment?

      from_category = Transaction::ACTIVITY_LABELS.find { |label| label.casecmp?(row.category.to_s) }
      from_category || Transaction.detect_activity_label(row.name, row.signed_amount)
    end

    # A statement's posting date routinely differs by a day or two from the date
    # a provider recorded for the same transaction, so matching allows a small
    # window rather than demanding an exact date.
    RECONCILIATION_DATE_WINDOW = 3

    # Splits candidate rows into those that are genuinely new and the existing
    # entries the rest already correspond to. Matching is per-account, so with no
    # account assigned yet every row is treated as new and judged again once the
    # user picks one (see assign_account!).
    def partition_already_recorded(candidates)
      return [ candidates, [] ] if account.blank?

      adapter = Account::ProviderImportAdapter.new(account)
      claimed = []
      unmatched = []
      matched = []

      candidates.each do |row|
        if (existing = already_recorded_entry(adapter, row, claimed))
          claimed << existing.id
          matched << existing
        else
          unmatched << row
        end
      end

      [ unmatched, matched ]
    end

    # Name is deliberately not part of the match: statement descriptions and
    # provider names for the same transaction rarely agree, and the adapter makes
    # the same choice for provider sync.
    def already_recorded_entry(adapter, row, claimed)
      adapter.find_duplicate_transaction(
        date: row.date_iso,
        amount: row.signed_amount,
        currency: row.currency,
        exclude_entry_ids: claimed,
        date_window: RECONCILIATION_DATE_WINDOW,
        include_provider_entries: true
      )
    rescue ArgumentError, TypeError => e # Date::Error subclasses ArgumentError
      # A row whose date or amount will not parse cannot be judged. Offer it for
      # import rather than dropping it silently -- the review step surfaces it.
      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: could not evaluate statement row for reconciliation (#{e.class})",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement_id,
          source_row_number: row.source_row_number,
          raw_date: row.date,
          raw_amount: row.amount,
          error_class: e.class.name
        }
      )
      nil
    end

    def reconcile_entries!(entries, at: Time.current)
      return if entries.blank?

      Entry.where(id: entries.map(&:id)).update_all(
        reconciled_at: at,
        reconciled_by_statement_id: account_statement&.id,
        updated_at: at
      )
    end

    # Regeneration can empty the row set (everything now matches) or refill it
    # (the new account matches nothing). Status has to follow, using the same
    # rule ProcessPdfJob applies after initial processing -- otherwise a
    # fully-matched import sits at pending with no rows, which renders as the
    # processing screen forever and cannot be restarted.
    def refresh_status_after_regeneration!
      return if data_committed?
      return unless pending? || complete?

      target = statement_with_transactions? && rows_count > 0 ? "pending" : "complete"
      update!(status: target) unless status.to_s == target
    end

    # Scoped to the account being moved away from. A statement is evidence for
    # exactly one account at a time, but it can back more than one import, so an
    # unscoped release would clear reconciliations another account still relies
    # on. Nothing is reconciled while no account is assigned, so a blank scope
    # has nothing to release.
    def release_reconciliations!(account_scope_id)
      return if account_statement.blank? || account_scope_id.blank?

      Entry.reconciled_by(account_statement).where(account_id: account_scope_id).update_all(
        reconciled_at: nil,
        reconciled_by_statement_id: nil,
        updated_at: Time.current
      )
    end

    # Reverting a statement import unwinds its evidence as well as its rows. The
    # entries it created are already destroyed by the time this runs; the ones it
    # only matched keep marks this statement no longer backs. Releasing and then
    # regenerating re-judges every statement line against what the account
    # actually holds now, so the review screen offers exactly what is missing.
    def revert_derived_state!
      release_reconciliations!(account_id)
      return unless has_extracted_transactions?

      generate_rows_from_extracted_data
      # A line that matched at publish time carried no row and so no mapping.
      # If it no longer matches it is a row again, and needs one.
      sync_mappings
    end

    # A statement whose every line still matches something -- a provider-synced
    # account, say -- reverts to zero rows. Returning that to pending renders the
    # processing screen with no way out, so an import with nothing left to offer
    # finishes as complete, the same way refresh_status_after_regeneration! ends
    # a fully reconciled import.
    def status_after_revert
      statement_with_transactions? && rows_count > 0 ? :pending : :complete
    end

    def format_date_for_import(date_str)
      return "" if date_str.blank?

      Date.parse(date_str).strftime(date_format)
    rescue ArgumentError
      date_str.to_s
    end

    def account_statement_matches_import
      return if account_statement.blank? || (account_statement.family_id == family_id && account_statement.pdf?)

      errors.add(:account_statement, :invalid)
    end
end
