class Provider::Openai::InvestmentStatementExtractor
  MAX_CHARS_PER_CHUNK = 3000
  attr_reader :client, :pdf_content, :model

  def initialize(client:, pdf_content:, model:)
    @client = client
    @pdf_content = pdf_content
    @model = model
  end

  # Cash-only pass: dividends, interest, fees, and contributions/withdrawals
  # that move money, not buys/sells/holdings. Those need a security match
  # (ticker -> Security) that a misread from a local, non-frontier model
  # writes straight into a real position — recording plain cash activity
  # here carries the same risk profile as the bank-statement extraction
  # that's already in production, and buy/sell support is deliberately left
  # for a later pass once this is proven out. Same chunking/shape as
  # BankStatementExtractor (so the result flows through the identical
  # PdfImport row-generation/import path) with an instructions set scoped to
  # cash activity only.
  def extract
    pages = extract_pages_from_pdf
    raise Provider::Openai::Error, "Could not extract text from PDF" if pages.empty?

    chunks = build_chunks(pages)
    Rails.logger.info("InvestmentStatementExtractor: Processing #{chunks.size} chunk(s) from #{pages.size} page(s)")

    all_transactions = []
    metadata = {}
    account_numbers = []
    # Per-account opening/closing balance, keyed by account_number — same
    # reasoning as Provider::Openai::BankStatementExtractor#extract: a combined
    # statement (brokerage + HSA + 401k from the same provider, say) reports a
    # different balance pair per account section, each stated only once on
    # whichever chunk that section's summary lands in.
    accounts_meta = {}

    chunks.each_with_index do |chunk, index|
      Rails.logger.info("InvestmentStatementExtractor: Processing chunk #{index + 1}/#{chunks.size}")
      # Every chunk (not just the first) is asked for its own account_number.
      # A combined statement starts a fresh account header on its own page, so
      # the per-page chunking above already segments the document by account —
      # without re-asking here, every chunk after the first silently inherits
      # no account context, and a second account's activity ends up tagged as
      # the first account's with nothing downstream able to tell them apart.
      result = process_chunk(chunk)
      # A page that does not repeat the account header continues the section
      # before it, so it keeps that section's number rather than none.
      chunk_account_number = result[:account_number].presence || account_numbers.last
      account_numbers << chunk_account_number if chunk_account_number.present?

      if chunk_account_number.present?
        meta = accounts_meta[chunk_account_number] ||= {}
        meta[:opening_balance] ||= result[:opening_balance] if result[:opening_balance].present?
        meta[:closing_balance] = result[:closing_balance] if result[:closing_balance].present?
        meta[:period_start] ||= result.dig(:period, :start_date) if result.dig(:period, :start_date).present?
        meta[:period_end] = result.dig(:period, :end_date) if result.dig(:period, :end_date).present?
      end

      # Tag transactions with chunk index (for dedup) and the account_number
      # detected on THIS chunk, so a multi-account statement's rows can later
      # be filtered down to the one account this import is actually for.
      tagged_transactions = (result[:transactions] || []).map do |t|
        t.merge(chunk_index: index, account_number: t[:account_number] || chunk_account_number)
      end
      all_transactions.concat(tagged_transactions)

      if index == 0
        metadata = {
          account_holder: result[:account_holder],
          account_number: result[:account_number],
          bank_name: result[:bank_name],
          opening_balance: result[:opening_balance],
          closing_balance: result[:closing_balance],
          period: result[:period]
        }
      end

      if result[:closing_balance].present?
        metadata[:closing_balance] = result[:closing_balance]
      end
      if result.dig(:period, :end_date).present?
        metadata[:period] ||= {}
        metadata[:period][:end_date] = result.dig(:period, :end_date)
      end
    end

    # Pages before the first account header belong to the first account.
    if (first_account_number = account_numbers.first)
      all_transactions.each { |t| t[:account_number] = first_account_number if t[:account_number].blank? }
    end

    {
      transactions: deduplicate_transactions(all_transactions),
      period: metadata[:period] || {},
      account_holder: metadata[:account_holder],
      account_number: metadata[:account_number],
      # Rows carry their own number too, so an account whose section never
      # restated it in a header is still counted.
      account_numbers: (account_numbers + all_transactions.filter_map { |t| t[:account_number].presence }).uniq,
      accounts: accounts_meta.map { |number, meta| meta.merge(account_number: number) },
      bank_name: metadata[:bank_name],
      opening_balance: metadata[:opening_balance],
      closing_balance: metadata[:closing_balance]
    }
  end

  private

    def extract_pages_from_pdf
      return [] if pdf_content.blank?

      reader = PDF::Reader.new(StringIO.new(pdf_content))
      reader.pages.map(&:text).reject(&:blank?)
    rescue => e
      Rails.logger.error("Failed to extract text from PDF: #{e.message}")
      []
    end

    def build_chunks(pages)
      chunks = []
      current_chunk = []
      current_size = 0

      pages.each do |page_text|
        if page_text.length > MAX_CHARS_PER_CHUNK
          chunks << current_chunk.join("\n\n") if current_chunk.any?
          current_chunk = []
          current_size = 0
          chunks << page_text
          next
        end

        if current_size + page_text.length > MAX_CHARS_PER_CHUNK && current_chunk.any?
          chunks << current_chunk.join("\n\n")
          current_chunk = []
          current_size = 0
        end

        current_chunk << page_text
        current_size += page_text.length
      end

      chunks << current_chunk.join("\n\n") if current_chunk.any?
      chunks
    end

    def process_chunk(text)
      params = {
        model: model,
        messages: [
          { role: "system", content: instructions_with_metadata },
          { role: "user", content: "Extract cash activity:\n\n#{text}" }
        ],
        response_format: { type: "json_object" }
      }

      response = client.chat(parameters: params)
      content = response.dig("choices", 0, "message", "content")

      raise Provider::Openai::Error, "No response from AI" if content.blank?

      parsed = parse_json_response(content)

      {
        transactions: normalize_transactions(parsed["transactions"] || []),
        period: {
          start_date: parsed.dig("statement_period", "start_date"),
          end_date: parsed.dig("statement_period", "end_date")
        },
        account_holder: parsed["account_holder"],
        account_number: parsed["account_number"],
        bank_name: parsed["bank_name"],
        opening_balance: parsed["opening_balance"],
        closing_balance: parsed["closing_balance"]
      }
    end

    def parse_json_response(content)
      cleaned = content.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("InvestmentStatementExtractor JSON parse error: #{e.message} (content_length=#{content.to_s.bytesize})")
      { "transactions" => [] }
    end

    def deduplicate_transactions(transactions)
      # Same chunk-boundary dedup as BankStatementExtractor — see that file's
      # comment for the accepted trade-off (a true same-day, same-amount,
      # same-name duplicate at a chunk boundary is dropped too). account_number
      # is part of the key so two different accounts on a combined statement
      # that happen to share a same-day, same-amount row near a chunk boundary
      # aren't wrongly collapsed into one.
      seen = Set.new
      transactions.select do |t|
        key = [ t[:date], t[:amount], t[:name], t[:account_number], t[:chunk_index] ]

        duplicate = seen.any? do |prev_key|
          prev_key[0..3] == key[0..3] && (prev_key[4] - key[4]).abs <= 1
        end

        seen << key
        !duplicate
      end.map { |t| t.except(:chunk_index) }
    end

    def normalize_transactions(transactions)
      transactions.map do |txn|
        {
          date: parse_date(txn["date"]),
          amount: parse_amount(txn["amount"]),
          name: txn["description"] || txn["name"],
          category: txn["activity_type"] || txn["category"],
          notes: txn["security"] || txn["notes"],
          account_number: txn["account_number"]
        }
      end.compact
    end

    def parse_date(date_str)
      return nil if date_str.blank?

      Date.parse(date_str).strftime("%Y-%m-%d")
    rescue ArgumentError
      nil
    end

    def parse_amount(amount)
      return nil if amount.nil?

      if amount.is_a?(Numeric)
        amount.to_f
      else
        amount.to_s.gsub(/[^0-9.\-]/, "").to_f
      end
    end

    def instructions_with_metadata
      <<~INSTRUCTIONS.strip
        Extract CASH activity from an investment/brokerage statement as JSON. Return:
        {"bank_name":"...","account_holder":"...","account_number":"last 4 digits","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"opening_balance":"a number, or null if not stated anywhere in this text","closing_balance":"a number, or null if not stated anywhere in this text","transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"activity_type":"Dividend|Interest|Fee|Contribution|Withdrawal|Other","security":"ticker or fund name, or null","account_number":"last 4 digits, or null"}]}

        opening_balance and closing_balance: use null, not 0.00, when this chunk's text does not
        actually state a balance figure anywhere (a transaction-ledger export with no account-value
        summary line is common -- do not treat "I didn't find one" as "the balance is zero").
        0.00 means the statement itself states the balance is exactly zero dollars.

        ONLY extract activity that moves cash in or out of the account:
          - Dividend or interest payments (positive amount)
          - Fees charged (negative amount)
          - Contributions, deposits, or employer/ESPP contributions (positive amount)
          - Withdrawals or cash distributions (negative amount)

        Do NOT extract:
          - Buy or sell trades of a security (no "bought 10 shares of X" rows)
          - Unrealized gains/losses or holding/position values
          - Account value summaries or balances (those go in opening_balance/closing_balance above, not transactions)
          - An in-kind securities transfer (e.g. "Received From You", "Transferred In/Out", a 401k-to-IRA
            rollover moving shares rather than cash, a "Fund to Fund" exchange). These move a security,
            not cash — $0 cash impact, never report a dollar amount equal to the security's value.

        #{duplicate_event_rule}

        This text is one chunk of a larger statement and may cover only part of it, so "account_number",
        "opening_balance", "closing_balance", and "statement_period" should describe only the account
        whose activity actually appears in THIS chunk. Some statements combine multiple accounts (e.g. a
        brokerage, an HSA, and a 401k from the same provider mailed as one combined statement) in one
        document, each with its own account number, its own opening/closing balance, and its own activity
        section — if this chunk starts a new account's section, report THAT account's numbers, not an
        earlier account's carried over from a prior chunk, and set each transaction's own "account_number"
        to the account whose section it actually appears in.

        Rules: Negative amounts for money leaving the account, positive for money arriving. Dates as YYYY-MM-DD. Include the security/fund name in "security" when the activity is tied to one (e.g. a dividend from a specific fund), otherwise null. If genuinely no cash activity exists in this statement, return an empty transactions array — do not invent rows. JSON only, no markdown.
      INSTRUCTIONS
    end

    def duplicate_event_rule
      "Investment statements routinely print the SAME real-world event more than once: a dividend " \
      "typically appears once in a \"Dividends, Interest & Other Income\" table AND again in a \"Core " \
      "Fund Activity\" / core-account sweep ledger showing it being reinvested, and sometimes a third " \
      "time in a month-end \"Taxable Dividends\" or tax-summary subtotal. Report each distinct " \
      "real-world event EXACTLY ONCE. Prefer the specific dated activity-ledger line over any subtotal, " \
      "period-total, or tax-summary row that merely restates an amount from elsewhere in this text. A " \
      "same-day \"Dividend Received\" paired with a \"Reinvestment\" of the identical amount is ONE " \
      "event (the dividend) — report it once, not as two transactions."
    end
end
