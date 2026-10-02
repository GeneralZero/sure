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

    chunks.each_with_index do |chunk, index|
      Rails.logger.info("InvestmentStatementExtractor: Processing chunk #{index + 1}/#{chunks.size}")
      result = process_chunk(chunk, index == 0)

      # Tag transactions with chunk index for deduplication
      tagged_transactions = (result[:transactions] || []).map { |t| t.merge(chunk_index: index) }
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

    {
      transactions: deduplicate_transactions(all_transactions),
      period: metadata[:period] || {},
      account_holder: metadata[:account_holder],
      account_number: metadata[:account_number],
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

    def process_chunk(text, is_first_chunk)
      params = {
        model: model,
        messages: [
          { role: "system", content: is_first_chunk ? instructions_with_metadata : instructions_transactions_only },
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
      # same-name duplicate at a chunk boundary is dropped too).
      seen = Set.new
      transactions.select do |t|
        key = [ t[:date], t[:amount], t[:name], t[:chunk_index] ]

        duplicate = seen.any? do |prev_key|
          prev_key[0..2] == key[0..2] && (prev_key[3] - key[3]).abs <= 1
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
          notes: txn["security"] || txn["notes"]
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
        {"bank_name":"...","account_holder":"...","account_number":"last 4 digits","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"opening_balance":0.00,"closing_balance":0.00,"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"activity_type":"Dividend|Interest|Fee|Contribution|Withdrawal|Other","security":"ticker or fund name, or null"}]}

        ONLY extract activity that moves cash in or out of the account:
          - Dividend or interest payments (positive amount)
          - Fees charged (negative amount)
          - Contributions, deposits, or employer/ESPP contributions (positive amount)
          - Withdrawals or cash distributions (negative amount)

        Do NOT extract:
          - Buy or sell trades of a security (no "bought 10 shares of X" rows)
          - Unrealized gains/losses or holding/position values
          - Account value summaries or balances (those go in opening_balance/closing_balance above, not transactions)

        Rules: Negative amounts for money leaving the account, positive for money arriving. Dates as YYYY-MM-DD. Include the security/fund name in "security" when the activity is tied to one (e.g. a dividend from a specific fund), otherwise null. If genuinely no cash activity exists in this statement, return an empty transactions array — do not invent rows. JSON only, no markdown.
      INSTRUCTIONS
    end

    def instructions_transactions_only
      <<~INSTRUCTIONS.strip
        Extract CASH activity from investment/brokerage statement text as JSON. Return:
        {"transactions":[{"date":"YYYY-MM-DD","description":"...","amount":-0.00,"activity_type":"Dividend|Interest|Fee|Contribution|Withdrawal|Other","security":"ticker or fund name, or null"}]}

        ONLY extract activity that moves cash in or out of the account (dividends, interest, fees, contributions, withdrawals) — never buy/sell trades, holdings, or balance summaries. Negative amounts for money leaving the account, positive for money arriving. Dates as YYYY-MM-DD. If genuinely no cash activity exists, return an empty transactions array. JSON only, no markdown.
      INSTRUCTIONS
    end
end
