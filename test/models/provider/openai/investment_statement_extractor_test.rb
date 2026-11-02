require "test_helper"

class Provider::Openai::InvestmentStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @client = mock("openai_client")
    @model = "gpt-4.1"
  end

  test "extracts cash activity from PDF content" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Fidelity",
            "account_holder" => "Jane Doe",
            "account_number" => "1234",
            "statement_period" => {
              "start_date" => "2024-01-01",
              "end_date" => "2024-01-31"
            },
            "opening_balance" => 50_000.00,
            "closing_balance" => 50_200.00,
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Dividend - VTI", "amount" => 150.00, "activity_type" => "Dividend", "security" => "VTI" },
              { "date" => "2024-01-20", "description" => "Account Fee", "amount" => -25.00, "activity_type" => "Fee", "security" => nil }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::InvestmentStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 investment statement text" ])

    result = extractor.extract

    assert_equal "Fidelity", result[:bank_name]
    assert_equal 2, result[:transactions].size

    dividend = result[:transactions].first
    assert_equal "2024-01-15", dividend[:date]
    assert_equal "Dividend - VTI", dividend[:name]
    assert_equal 150.00, dividend[:amount]
    assert_equal "Dividend", dividend[:category]
    assert_equal "VTI", dividend[:notes]

    fee = result[:transactions].second
    assert_equal "Fee", fee[:category]
    assert_equal(-25.00, fee[:amount])
  end

  test "tags each chunk's transactions with that chunk's own account_number for a combined statement" do
    brokerage_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Fidelity",
            "account_number" => "5678",
            "opening_balance" => 90_000.00,
            "closing_balance" => 92_000.00,
            "transactions" => [
              { "date" => "2026-03-05", "description" => "Dividend - AON", "amount" => 150.00, "activity_type" => "Dividend" }
            ]
          }.to_json
        }
      } ]
    }

    hsa_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "account_number" => "1234",
            "opening_balance" => 8_000.00,
            "closing_balance" => 8_050.00,
            "transactions" => [
              { "date" => "2026-03-10", "description" => "HSA Dividend Received", "amount" => 50.00, "activity_type" => "Dividend" }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(brokerage_response, hsa_response)

    extractor = Provider::Openai::InvestmentStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    # Two long pages force two chunks, one per account section.
    extractor.stubs(:extract_pages_from_pdf).returns([ "Brokerage page " * 500, "HSA page " * 500 ])

    result = extractor.extract

    brokerage_txn = result[:transactions].find { |t| t[:name] == "Dividend - AON" }
    hsa_txn = result[:transactions].find { |t| t[:name] == "HSA Dividend Received" }
    assert_equal "5678", brokerage_txn[:account_number]
    assert_equal "1234", hsa_txn[:account_number]

    assert_equal %w[5678 1234], result[:account_numbers]
    hsa_account = result[:accounts].find { |a| a[:account_number] == "1234" }
    assert_equal 8_000.00, hsa_account[:opening_balance]
    assert_equal 8_050.00, hsa_account[:closing_balance]
  end

  test "returns an empty transaction list when the statement has no cash activity" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => { "transactions" => [] }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::InvestmentStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 holdings-only statement text" ])

    result = extractor.extract

    assert_equal [], result[:transactions]
  end

  test "handles empty PDF content" do
    extractor = Provider::Openai::InvestmentStatementExtractor.new(
      client: @client,
      pdf_content: "",
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "handles malformed JSON response gracefully" do
    mock_response = {
      "choices" => [ {
        "message" => { "content" => "not valid JSON" }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::InvestmentStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    assert_equal [], result[:transactions]
  end
end
