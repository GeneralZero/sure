require "test_helper"
require "ostruct"

class Provider::Anthropic::InvestmentStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @pdf_content = "%PDF-1.4 fake bytes".b
  end

  test "sends PDF as native document and returns normalized cash activity + metadata" do
    fake_response = build_response(content: [
      tool_use_block(
        id: "toolu_1",
        name: "report_investment_statement",
        input: {
          "bank_name" => "Fidelity",
          "account_holder" => "Jane Doe",
          "account_number" => "1234",
          "statement_period" => { "start_date" => "2026-03-01", "end_date" => "2026-03-31" },
          "opening_balance" => 50_000.0,
          "closing_balance" => 50_200.0,
          "transactions" => [
            { "date" => "2026-03-05", "description" => "Dividend - VTI", "amount" => 150.0, "activity_type" => "Dividend", "security" => "VTI" },
            { "date" => "2026-03-15", "description" => "Account Fee", "amount" => -25.0, "activity_type" => "Fee" }
          ]
        }
      )
    ])
    client = stub_client(fake_response)

    result = Provider::Anthropic::InvestmentStatementExtractor.new(
      client: client,
      model: "claude-sonnet-4-6",
      pdf_content: @pdf_content
    ).extract

    assert_equal "Fidelity", result[:bank_name]
    assert_equal "Jane Doe", result[:account_holder]
    assert_equal "2026-03-01", result[:period][:start_date]
    assert_equal 50_000.0, result[:opening_balance]

    assert_equal 2, result[:transactions].size
    dividend = result[:transactions].first
    assert_equal "2026-03-05", dividend[:date]
    assert_equal "Dividend - VTI", dividend[:name]
    assert_equal 150.0, dividend[:amount]
    assert_equal "Dividend", dividend[:category]
    assert_equal "VTI", dividend[:notes]

    fee = result[:transactions].last
    assert_equal "Fee", fee[:category]
    assert_equal(-25.0, fee[:amount])
  end

  test "raises when pdf_content is blank" do
    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::InvestmentStatementExtractor.new(
        client: mock,
        model: "claude-sonnet-4-6",
        pdf_content: nil
      ).extract
    end
    assert_match(/PDF content is required/i, err.message)
  end

  test "raises when model omits the tool call" do
    fake_response = build_response(content: [ OpenStruct.new(type: :text, text: "no tool") ])
    client = stub_client(fake_response)

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::InvestmentStatementExtractor.new(
        client: client,
        model: "claude-sonnet-4-6",
        pdf_content: @pdf_content
      ).extract
    end
    assert_match(/did not invoke report_investment_statement/i, err.message)
  end

  test "raises before API call when pdf_content exceeds the 32 MB limit" do
    oversized = "a".b * (Provider::Anthropic::InvestmentStatementExtractor::MAX_PDF_BYTES + 1)
    client = mock
    client.expects(:messages).never

    err = assert_raises(Provider::Anthropic::Error) do
      Provider::Anthropic::InvestmentStatementExtractor.new(
        client: client,
        model: "claude-sonnet-4-6",
        pdf_content: oversized
      ).extract
    end
    assert_match(/exceeds Anthropic's 32 MB limit/i, err.message)
  end

  test "returns an empty transaction list when the statement has no cash activity" do
    fake_response = build_response(content: [
      tool_use_block(id: "toolu_1", name: "report_investment_statement", input: { "transactions" => [] })
    ])
    client = stub_client(fake_response)

    result = Provider::Anthropic::InvestmentStatementExtractor.new(
      client: client,
      model: "claude-sonnet-4-6",
      pdf_content: @pdf_content
    ).extract

    assert_equal [], result[:transactions]
  end

  private
    def stub_client(response)
      messages = mock
      messages.stubs(:create).returns(response)
      client = mock
      client.stubs(:messages).returns(messages)
      client
    end

    def build_response(content:, usage: { input_tokens: 1500, output_tokens: 400 })
      OpenStruct.new(
        id: "msg_test",
        model: "claude-sonnet-4-6",
        content: content,
        usage: OpenStruct.new(input_tokens: usage[:input_tokens], output_tokens: usage[:output_tokens])
      )
    end

    def tool_use_block(id:, name:, input:)
      OpenStruct.new(type: :tool_use, id: id, name: name, input: input)
    end
end
