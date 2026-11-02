class Provider::Anthropic::InvestmentStatementExtractor
  include Provider::Anthropic::Concerns::UsageRecorder

  TOOL_NAME = "report_investment_statement".freeze

  # Mirrors Provider::Anthropic::PdfProcessor::MAX_PDF_BYTES.
  MAX_PDF_BYTES = 32 * 1024 * 1024

  attr_reader :client, :model, :pdf_content, :langfuse_trace, :family

  def initialize(client:, model:, pdf_content:, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @langfuse_trace = langfuse_trace
    @family = family
  end

  # Cash-only pass: dividends, interest, fees, and contributions/withdrawals
  # that move money, not buys/sells/holdings — see
  # Provider::Openai::InvestmentStatementExtractor's header comment for why
  # trade extraction is deliberately out of scope here.
  def extract
    raise Provider::Anthropic::Error, "PDF content is required" if pdf_content.blank?
    if pdf_content.bytesize > MAX_PDF_BYTES
      raise Provider::Anthropic::Error,
            "PDF exceeds Anthropic's 32 MB limit (#{pdf_content.bytesize} bytes)"
    end

    span = langfuse_trace&.span(name: "extract_investment_statement_api_call", input: {
      model: model,
      pdf_size: pdf_content.bytesize
    })

    response = client.messages.create(
      model: model,
      max_tokens: max_tokens,
      system_: instructions,
      messages: [ { role: "user", content: user_content } ],
      tools: [ output_tool ],
      tool_choice: { type: "tool", name: TOOL_NAME, disable_parallel_tool_use: true }
    )

    parsed = extract_tool_input(response)
    result = build_result(parsed)

    truncated = stop_reason(response) == :max_tokens
    if truncated
      Rails.logger.warn(
        "[InvestmentStatementExtractor] response truncated by max_tokens — extracted #{result[:transactions].size} " \
        "cash transactions but more may be present in the statement. Raise ANTHROPIC_MAX_TOKENS or chunk the PDF."
      )
      result[:truncated] = true
    end

    record_usage(model, response.usage, operation: "extract_investment_statement", metadata: {
      pdf_size: pdf_content.bytesize,
      transaction_count: result[:transactions].size,
      truncated: truncated
    })

    span&.end(output: { transaction_count: result[:transactions].size }, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "extract_investment_statement", error: e, metadata: { pdf_size: pdf_content&.bytesize })
    raise
  end

  private
    def max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", 4096).to_i
    end

    def user_content
      [
        {
          type: "document",
          source: {
            type: "base64",
            media_type: "application/pdf",
            data: Base64.strict_encode64(pdf_content)
          }
        },
        {
          type: "text",
          text: "Extract every cash-moving activity (dividends, interest, fees, contributions, withdrawals) from this investment statement and return them via the #{TOOL_NAME} tool. Do not extract buy/sell trades or holdings."
        }
      ]
    end

    def output_tool
      {
        name: TOOL_NAME,
        description: "Return the cash activity (dividends, interest, fees, contributions, withdrawals) and statement metadata extracted from the PDF. Never buy/sell trades or holdings.",
        input_schema: {
          type: "object",
          properties: {
            bank_name: { type: [ "string", "null" ], description: "The brokerage/institution name." },
            account_holder: { type: [ "string", "null" ] },
            account_number: { type: [ "string", "null" ], description: "Typically last 4 digits only." },
            statement_period: {
              type: "object",
              properties: {
                start_date: { type: [ "string", "null" ], description: "YYYY-MM-DD" },
                end_date: { type: [ "string", "null" ], description: "YYYY-MM-DD" }
              },
              required: [],
              additionalProperties: false
            },
            opening_balance: { type: [ "number", "null" ], description: "null when this statement does not state a balance figure anywhere (e.g. a transaction-ledger export with no account-value summary line) -- do not use 0 to mean 'not found'; 0 means the statement itself states the balance is exactly zero." },
            closing_balance: { type: [ "number", "null" ], description: "Same rule as opening_balance: null when not stated, never as a stand-in for 'not found'." },
            accounts: {
              type: "array",
              description: "One entry per account the document covers. A single-account statement has exactly one; a combined statement (e.g. a brokerage + HSA + 401k statement from the same provider, each on its own pages) has one per account section, each with its own balances and period.",
              items: {
                type: "object",
                properties: {
                  account_number: { type: [ "string", "null" ], description: "Last 4 digits." },
                  opening_balance: { type: [ "number", "null" ], description: "null when not stated anywhere in this account's section -- never 0 as a stand-in for 'not found'." },
                  closing_balance: { type: [ "number", "null" ], description: "Same rule as opening_balance: null when not stated, never as a stand-in for 'not found'." },
                  period_start: { type: [ "string", "null" ], description: "YYYY-MM-DD" },
                  period_end: { type: [ "string", "null" ], description: "YYYY-MM-DD" }
                },
                required: [],
                additionalProperties: false
              }
            },
            transactions: {
              type: "array",
              description: "Every DISTINCT real-world cash-moving event in the statement, in document order. Never a buy/sell trade or a holding/position. Each event appears exactly once, even if the statement itself prints it more than once (see instructions).",
              items: {
                type: "object",
                properties: {
                  date: { type: "string", description: "YYYY-MM-DD" },
                  description: { type: "string" },
                  amount: { type: "number", description: "Negative for money leaving the account, positive for money arriving." },
                  activity_type: { type: [ "string", "null" ], description: "One of: Dividend, Interest, Fee, Contribution, Withdrawal, Other" },
                  security: { type: [ "string", "null" ], description: "Ticker or fund name this activity is tied to, if any." },
                  account_number: {
                    type: [ "string", "null" ],
                    description: "Last 4 digits of the account THIS activity belongs to. Only needed when the document combines more than one account (e.g. a brokerage + HSA + 401k statement from the same provider); null or omitted for an ordinary single-account statement."
                  }
                },
                required: [ "date", "description", "amount" ],
                additionalProperties: false
              }
            }
          },
          required: [ "transactions" ],
          additionalProperties: false
        }
      }
    end

    def instructions
      <<~INSTRUCTIONS
        Extract CASH activity from the attached investment/brokerage statement and return the result via the #{TOOL_NAME} tool.

        ONLY extract activity that moves cash in or out of the account:
          - Dividend or interest payments (positive amount)
          - Fees charged (negative amount)
          - Contributions, deposits, or employer/ESPP contributions (positive amount)
          - Withdrawals or cash distributions (negative amount)

        Rules:
          - Do NOT extract buy/sell trades of a security, unrealized gains/losses, holdings, positions, or balance summaries
          - Do NOT extract an in-kind securities transfer (e.g. "Received From You", "Transferred In/Out",
            a 401k-to-IRA rollover moving shares rather than cash, a plan-to-plan "Fund to Fund" exchange).
            These move a security, not cash — they have $0 cash impact and must never be reported as a
            transaction with a dollar amount equal to the security's value.
          - Investment statements routinely print the SAME real-world event more than once: a dividend
            typically appears once in a "Dividends, Interest & Other Income" table AND again in a
            "Core Fund Activity" / core-account sweep ledger showing it being reinvested, and sometimes a
            third time in a month-end "Taxable Dividends" or tax-summary subtotal. Report each distinct
            real-world event EXACTLY ONCE. Prefer the specific dated activity-ledger line over any
            subtotal, period-total, or tax-summary row that merely restates an amount from elsewhere on
            the statement. A same-day "Dividend Received" paired with a "Reinvestment" of the identical
            amount is ONE event (the dividend) — report it once, not as two transactions.
          - Negative amounts for money leaving the account, positive for money arriving
          - Dates in YYYY-MM-DD
          - Use null for any field you cannot read; do not invent values
          - opening_balance and closing_balance specifically: a transaction-ledger export often has no
            account-value summary line anywhere in the text. When that is the case, these must be null,
            not 0 — 0 means the statement itself states the balance is exactly zero dollars, which is a
            different fact than "no balance figure was printed here."
          - If genuinely no cash activity exists in this statement, return an empty transactions array
          - Some statements combine multiple accounts in one document (e.g. a brokerage, an HSA, and a
            401k from the same provider, each with its own account number and its own activity section —
            common when a provider mails one combined statement per household). When that happens: set
            each transaction's own account_number to the account whose section it actually appears in —
            do not leave every transaction tagged with just the first account found — and report one
            entry per account in "accounts", each with that account's own balances and period.
      INSTRUCTIONS
    end

    def stop_reason(response)
      raw = response.respond_to?(:stop_reason) ? response.stop_reason : nil
      raw.to_s.to_sym if raw
    end

    def extract_tool_input(response)
      tool_use = Array(response.content).find { |block| block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME}" unless tool_use

      input = block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      input
    end

    def build_result(parsed)
      # Not deduplicated — see Provider::Anthropic::BankStatementExtractor's
      # build_result comment for why (whole PDF sent as one native document
      # block, no chunk artifacts to dedupe).
      transactions = Array(parsed["transactions"] || parsed[:transactions]).map { |t| normalize_transaction(t) }.compact

      {
        transactions: transactions,
        period: {
          start_date: dig_period(parsed, :start_date),
          end_date: dig_period(parsed, :end_date)
        },
        account_holder: parsed["account_holder"] || parsed[:account_holder],
        account_number: parsed["account_number"] || parsed[:account_number],
        account_numbers: transactions.map { |t| t[:account_number] }.compact.uniq,
        accounts: normalize_accounts(parsed["accounts"] || parsed[:accounts]),
        bank_name: parsed["bank_name"] || parsed[:bank_name],
        opening_balance: parsed["opening_balance"] || parsed[:opening_balance],
        closing_balance: parsed["closing_balance"] || parsed[:closing_balance]
      }
    end

    def normalize_accounts(accounts)
      Array(accounts).filter_map do |a|
        next nil unless a.is_a?(Hash)

        {
          account_number: a["account_number"] || a[:account_number],
          opening_balance: a["opening_balance"] || a[:opening_balance],
          closing_balance: a["closing_balance"] || a[:closing_balance],
          period_start: a["period_start"] || a[:period_start],
          period_end: a["period_end"] || a[:period_end]
        }
      end
    end

    def dig_period(parsed, key)
      period = parsed["statement_period"] || parsed[:statement_period]
      return nil unless period.is_a?(Hash)
      period[key.to_s] || period[key]
    end

    def normalize_transaction(txn)
      return nil unless txn.is_a?(Hash)

      {
        date: parse_date(txn["date"] || txn[:date]),
        amount: parse_amount(txn["amount"] || txn[:amount]),
        name: txn["description"] || txn[:description] || txn["name"] || txn[:name],
        category: txn["activity_type"] || txn[:activity_type] || txn["category"] || txn[:category],
        notes: txn["security"] || txn[:security] || txn["notes"] || txn[:notes],
        account_number: txn["account_number"] || txn[:account_number]
      }
    end

    def parse_date(date_str)
      return nil if date_str.blank?
      Date.parse(date_str.to_s).strftime("%Y-%m-%d")
    rescue ArgumentError
      nil
    end

    def parse_amount(amount)
      return nil if amount.nil?
      return amount.to_f if amount.is_a?(Numeric)
      amount.to_s.gsub(/[^0-9.\-]/, "").to_f
    end

    def block_type(block)
      raw = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
      raw.to_s.to_sym
    end

    def block_input(block)
      block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    end

    def usage_hash(raw_usage)
      return {} unless raw_usage
      {
        "input_tokens" => raw_usage.input_tokens.to_i,
        "output_tokens" => raw_usage.output_tokens.to_i,
        "total_tokens" => raw_usage.input_tokens.to_i + raw_usage.output_tokens.to_i
      }
    end
end
