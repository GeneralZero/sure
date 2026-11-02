class Provider::Openai::BankStatementExtractor
  include Provider::Openai::Concerns::JsonMode

  MAX_CHARS_PER_CHUNK = 3000
  attr_reader :client, :pdf_content, :model, :json_mode

  def initialize(client:, pdf_content:, model:, json_mode: nil)
    @client = client
    @pdf_content = pdf_content
    @model = model
    @json_mode = json_mode || default_json_mode
  end

  def extract
    pages = extract_pages_from_pdf
    raise Provider::Openai::Error, "Could not extract text from PDF" if pages.empty?

    chunks = build_chunks(pages)
    Rails.logger.info("BankStatementExtractor: Processing #{chunks.size} chunk(s) from #{pages.size} page(s)")

    all_transactions = []
    metadata = {}
    account_numbers = []
    # Per-account opening/closing balance, keyed by account_number. A combined
    # statement reports a DIFFERENT balance pair for each account section, and
    # each is only ever stated once (on whichever chunk that section's summary
    # lands in) -- unlike account_number, re-asking every chunk isn't enough on
    # its own, this also has to be collected per-account rather than overwritten
    # by whichever chunk happens to run last.
    accounts_meta = {}

    chunks.each_with_index do |chunk, index|
      Rails.logger.info("BankStatementExtractor: Processing chunk #{index + 1}/#{chunks.size}")
      # Every chunk (not just the first) is asked for its own account_number.
      # A combined statement (e.g. Ally's checking + savings on one PDF) starts
      # a fresh account header on its own page, so the per-page chunking above
      # already segments the document by account -- without re-asking here,
      # every chunk after the first silently inherits no account context at
      # all, and a second account's transactions end up tagged as the first
      # account's with nothing downstream able to tell them apart.
      result = process_chunk(chunk)
      # A page that does not repeat the account header continues the section
      # before it, so it keeps that section's number rather than none.
      chunk_account_number = result[:account_number].presence || account_numbers.last
      account_numbers << chunk_account_number if chunk_account_number.present?

      if chunk_account_number.present?
        meta = accounts_meta[chunk_account_number] ||= {}
        # First sighting of this account's opening balance wins (the earliest
        # chunk mentioning it is the one with its period's actual start);
        # closing balance keeps being overwritten so the last sighting wins.
        meta[:opening_balance] ||= result[:opening_balance] if result[:opening_balance].present?
        meta[:closing_balance] = result[:closing_balance] if result[:closing_balance].present?
        meta[:period_start] ||= result.dig(:period, :start_date) if result.dig(:period, :start_date).present?
        meta[:period_end] = result.dig(:period, :end_date) if result.dig(:period, :end_date).present?
      end

      # Tag transactions with chunk index (for dedup), the account_number
      # detected on THIS chunk so a multi-account statement's rows can later
      # be filtered down to the one account this import is actually for, and
      # transfer_counterparty_account_number so a transfer description that
      # names an account can be checked against account_number in code
      # (deterministically, rather than trusting the model to reason about
      # which account a self-referential description really belongs to).
      tagged_transactions = (result[:transactions] || []).map do |t|
        t.merge(
          chunk_index: index,
          account_number: chunk_account_number,
          transfer_counterparty_account_number: t[:transfer_counterparty_account_number]
        )
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
      account_numbers: account_numbers.uniq,
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
          { role: "user", content: "Extract transactions:\n\n#{text}" }
        ]
      }

      apply_json_mode(params, mode: json_mode)

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
      Rails.logger.error("BankStatementExtractor JSON parse error: #{e.message} (content_length=#{content.to_s.bytesize})")
      { "transactions" => [] }
    end

    def deduplicate_transactions(transactions)
      # Deduplicates transactions that appear in consecutive chunks (chunking artifacts).
      #
      # Also requires the account_number to match (or both be blank) -- without that,
      # two different accounts on a combined statement that happen to share a same-day,
      # same-amount, same-description transaction in adjacent chunks would otherwise be
      # wrongly collapsed into one.
      #
      # KNOWN LIMITATION: Legitimate duplicate transactions (same date, amount, merchant,
      # AND account) that happen to appear in adjacent chunks will be incorrectly
      # deduplicated. This is an acceptable trade-off since chunking artifacts are more
      # common than true same-day duplicates at chunk boundaries. Transactions within the
      # same chunk are always preserved regardless of similarity.
      seen = Set.new
      transactions.select do |t|
        key = [ t[:date], t[:amount], t[:name], t[:account_number], t[:chunk_index] ]

        # Check if we've seen this exact transaction (same account) in a different chunk
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
          name: txn["description"] || txn["name"] || txn["merchant"],
          category: infer_category(txn),
          notes: txn["reference"] || txn["notes"],
          transfer_counterparty_account_number: txn["transfer_counterparty_account_number"]
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

    def infer_category(txn)
      txn["category"] || txn["type"]
    end

    def instructions_with_metadata
      <<~INSTRUCTIONS.strip
        Extract bank statement data as JSON. Return:
        {"bank_name":"...","account_holder":"...","account_number":"last 4 digits","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"opening_balance":0.00,"closing_balance":0.00,"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"transfer_counterparty_account_number":null}]}

        Rules: Negative amounts for debits/expenses, positive for credits/deposits. Dates as YYYY-MM-DD. Extract ALL transactions. JSON only, no markdown.

        This text is one chunk of a larger statement and may cover only part of it, so
        "account_number", "opening_balance", "closing_balance", and "statement_period" should
        describe only the account whose activity actually appears in THIS chunk. Some statements
        combine multiple accounts (e.g. a checking and a savings account) in one document, each
        with its own account number, its own opening/closing balance, and its own activity
        section -- if this chunk starts a new account's section, report THAT account's numbers,
        not an earlier account's carried over from a prior chunk.

        "transfer_counterparty_account_number" is for internal transfers only: when a
        transaction's own description names an account number (e.g. "transfer to Savings
        account 1234" or "transfer from Checking 5678"), put that number here. Leave it null
        for anything that isn't a transfer between the customer's own accounts. Just read the
        digits the description states -- do not try to work out which account this transaction
        should actually belong to, that is figured out separately from what you report here.
      INSTRUCTIONS
    end
end
