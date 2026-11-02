class Provider::Anthropic::BankStatementExtractor
  include Provider::Anthropic::Concerns::UsageRecorder
  include Provider::Anthropic::Concerns::StructuredOutput

  TOOL_NAME = "report_bank_statement".freeze

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

  def extract
    raise Provider::Anthropic::Error, "PDF content is required" if pdf_content.blank?
    if pdf_content.bytesize > MAX_PDF_BYTES
      raise Provider::Anthropic::Error,
            "PDF exceeds Anthropic's 32 MB limit (#{pdf_content.bytesize} bytes)"
    end

    span = langfuse_trace&.generation(name: "extract_bank_statement_api_call", model: model, input: {
      model: model,
      pdf_size: pdf_content.bytesize
    })

    response = create_structured_message(
      tool_name: TOOL_NAME,
      operation: "extract_bank_statement",
      model: model,
      max_tokens: max_tokens,
      system_: Provider::Anthropic.structured_output_system(instructions, model, TOOL_NAME),
      messages: [ { role: "user", content: user_content } ],
      tools: [ output_tool ],
      tool_choice: Provider::Anthropic.structured_output_tool_choice(model, TOOL_NAME)
    )

    parsed = extract_tool_input(response)
    result = build_result(parsed)

    truncated = stop_reason(response) == :max_tokens
    if truncated
      Rails.logger.warn(
        "[BankStatementExtractor] response truncated by max_tokens — extracted #{result[:transactions].size} " \
        "transactions but more may be present in the statement. Raise ANTHROPIC_MAX_TOKENS or chunk the PDF."
      )
      result[:truncated] = true
    end

    record_usage(model, response.usage, operation: "extract_bank_statement", metadata: {
      pdf_size: pdf_content.bytesize,
      transaction_count: result[:transactions].size,
      truncated: truncated
    })

    span&.end(output: { transaction_count: result[:transactions].size }, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: "extract_bank_statement", error: e, metadata: { pdf_size: pdf_content&.bytesize })
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
          text: "Extract every transaction from this bank statement and return them via the report_bank_statement tool."
        }
      ]
    end

    def output_tool
      {
        name: TOOL_NAME,
        description: "Return the full set of transactions and statement metadata extracted from the PDF.",
        input_schema: {
          type: "object",
          properties: {
            bank_name: { type: [ "string", "null" ] },
            account_holder: { type: [ "string", "null" ] },
            account_number: { type: [ "string", "null" ], description: "Typically last 4 digits only. When the document combines more than one account, this is the first account's -- rely on each transaction's own account_number instead." },
            statement_period: {
              type: "object",
              properties: {
                start_date: { type: [ "string", "null" ], description: "YYYY-MM-DD" },
                end_date: { type: [ "string", "null" ], description: "YYYY-MM-DD" }
              },
              required: [],
              additionalProperties: false
            },
            opening_balance: { type: [ "number", "null" ], description: "The first account's, when the document combines more than one -- rely on the accounts array for the rest." },
            closing_balance: { type: [ "number", "null" ], description: "The first account's, when the document combines more than one -- rely on the accounts array for the rest." },
            accounts: {
              type: "array",
              description: "One entry per account the document covers. A single-account statement has exactly one; a combined statement (e.g. a checking + savings statement from the same bank) has one per account section, each with its own balances and period.",
              items: {
                type: "object",
                properties: {
                  account_number: { type: [ "string", "null" ], description: "Last 4 digits." },
                  opening_balance: { type: [ "number", "null" ] },
                  closing_balance: { type: [ "number", "null" ] },
                  period_start: { type: [ "string", "null" ], description: "YYYY-MM-DD" },
                  period_end: { type: [ "string", "null" ], description: "YYYY-MM-DD" }
                },
                required: [],
                additionalProperties: false
              }
            },
            transactions: {
              type: "array",
              description: "Every transaction in the statement, in document order.",
              items: {
                type: "object",
                properties: {
                  date: { type: "string", description: "YYYY-MM-DD" },
                  description: { type: "string" },
                  amount: { type: "number", description: "Negative for debits / expenses, positive for credits / deposits." },
                  reference: { type: [ "string", "null" ] },
                  category: { type: [ "string", "null" ] },
                  account_number: {
                    type: [ "string", "null" ],
                    description: "Last 4 digits of the account THIS transaction belongs to. Only needed when the document combines more than one account (e.g. a checking + savings statement); null or omitted for an ordinary single-account statement."
                  },
                  transfer_counterparty_account_number: {
                    type: [ "string", "null" ],
                    description: "For an internal transfer only: when the transaction's own description names an account number (e.g. 'transfer to Savings account 1234' or 'transfer from Checking 5678'), the number it names. Null for anything that isn't a transfer between the customer's own accounts. Just report the digits the description states -- do not try to work out which account this transaction should actually belong to; that is figured out separately."
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
        Extract bank statement data from the attached PDF and return the result via the report_bank_statement tool.

        Rules:
          - Extract EVERY transaction in document order
          - Negative amounts for debits / expenses, positive for credits / deposits
          - Dates in YYYY-MM-DD
          - Use null for any field you cannot read; do not invent values
          - Some statements combine multiple accounts in one document (e.g. a checking
            and a savings account from the same bank, each with its own account number,
            own opening/closing balance, and its own activity section). When that
            happens: set each transaction's own account_number to the account whose
            section it actually appears in -- do not leave every transaction tagged
            with just the first account found -- and report one entry per account in
            "accounts", each with that account's own balances and period.
          - For a transaction that is an internal transfer whose own description names
            an account number, put that number in transfer_counterparty_account_number.
            Just report the digits the description states; do not try to work out which
            account the transaction should actually belong to.
      INSTRUCTIONS
    end

    def stop_reason(response)
      raw = response.respond_to?(:stop_reason) ? response.stop_reason : nil
      raw.to_s.to_sym if raw
    end

    def extract_tool_input(response)
      tool_use = Array(response.content).find { |block| structured_block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME} (stop_reason: #{stop_reason(response)})" unless tool_use

      input = structured_block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      input
    end

    def build_result(parsed)
      # Intentionally NOT deduplicated, unlike Provider::Openai's extractor. That
      # one chunks the PDF text with overlap and must drop transactions repeated
      # across adjacent chunks. We send the whole PDF as a single native document
      # block — no chunk artifacts — so deduping here would wrongly merge
      # legitimate same-day, same-amount rows (e.g. two identical purchases).
      # Preserve every transaction the model returns.
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
        category: txn["category"] || txn[:category],
        notes: txn["reference"] || txn[:reference],
        account_number: txn["account_number"] || txn[:account_number],
        transfer_counterparty_account_number: txn["transfer_counterparty_account_number"] || txn[:transfer_counterparty_account_number]
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
end
