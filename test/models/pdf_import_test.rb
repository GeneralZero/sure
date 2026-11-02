require "test_helper"

class PdfImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @import = imports(:pdf)
    @processed_import = imports(:pdf_processed)
    @import_with_rows = imports(:pdf_with_rows)
  end

  test "pdf_uploaded? returns false when no file attached" do
    assert_not @import.pdf_uploaded?
  end

  test "pdf_uploaded? returns true for statement backed import" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert import.pdf_uploaded?
    assert import.statement_backed?
    assert_equal statement.original_file.download, import.pdf_file_content
    assert_equal statement.filename, import.pdf_filename
  end

  test "ai_processed? returns false when no summary present" do
    assert_not @import.ai_processed?
  end

  test "ai_processed? returns true when summary present" do
    assert @processed_import.ai_processed?
  end

  test "uploaded? delegates to pdf_uploaded?" do
    assert_not @import.uploaded?
  end

  test "configured? requires AI processed and rows" do
    assert_not @import.configured?
    assert_not @processed_import.configured?
    assert @import_with_rows.configured?
  end

  test "cleaned? requires configured and valid rows" do
    assert_not @import.cleaned?
    assert_not @processed_import.cleaned?
  end

  test "publishable? requires bank statement with cleaned rows and valid mappings" do
    assert_not @import.publishable?
    assert_not @processed_import.publishable?
  end

  test "status detail cleaned check requires account and transaction statement" do
    @import_with_rows.update!(account: accounts(:depository), document_type: "bank_statement")

    assert @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 1)

    @import_with_rows.update!(account: nil)
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)

    @import_with_rows.update!(account: accounts(:depository), document_type: "other")
    assert_not @import_with_rows.cleaned_from_validation_stats?(invalid_rows_count: 0)
  end

  test "column_keys returns transaction columns" do
    assert_equal %i[date amount name category notes], @import.column_keys
  end

  test "required_column_keys returns date and amount" do
    assert_equal %i[date amount], @import.required_column_keys
  end

  test "document_type validates against allowed types" do
    @import.document_type = "bank_statement"
    assert @import.valid?

    @import.document_type = "invalid_type"
    assert_not @import.valid?
    assert @import.errors[:document_type].present?
  end

  test "document_type allows nil" do
    @import.document_type = nil
    assert @import.valid?
  end

  test "investment_statement? is true only for investment_statement" do
    @import.document_type = "investment_statement"
    assert @import.investment_statement?

    @import.document_type = "bank_statement"
    assert_not @import.investment_statement?
  end

  test "statement_with_transactions? includes investment statements" do
    @import.document_type = "investment_statement"
    assert @import.statement_with_transactions?

    @import.document_type = "bank_statement"
    assert @import.statement_with_transactions?

    @import.document_type = "credit_card_statement"
    assert @import.statement_with_transactions?

    @import.document_type = "financial_document"
    assert_not @import.statement_with_transactions?
  end

  test "import! sets investment_activity_label on investment accounts, from the row's AI-assigned category" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement(account: accounts(:investment)))
    import.update!(document_type: "investment_statement")

    Import::Row.create!(
      import: import,
      source_row_number: 1,
      date: Date.current.strftime(import.date_format),
      amount: "-150.00",
      name: "Dividend - VTI",
      category: "Dividend",
      currency: "USD"
    )
    import.rows.reset

    import.import!

    entry = import.account.entries.find_by!(name: "Dividend - VTI")
    assert_equal "Dividend", entry.entryable.investment_activity_label
  end

  test "import! sets investment_contribution kind and dedicated category for contribution rows" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement(account: accounts(:investment)))
    import.update!(document_type: "investment_statement")

    Import::Row.create!(
      import: import,
      source_row_number: 1,
      date: Date.current.strftime(import.date_format),
      amount: "500.00",
      name: "401k Contribution",
      category: "Contribution",
      currency: "USD"
    )
    import.rows.reset

    import.import!

    entry = import.account.entries.find_by!(name: "401k Contribution")
    transaction = entry.entryable
    assert_equal "Contribution", transaction.investment_activity_label
    assert_equal "investment_contribution", transaction.kind
    assert_equal import.family.investment_contributions_category, transaction.category
  end

  test "import! backfills opening balance from the statement when nothing predates it" do
    account = accounts(:depository)
    period_start = 10.days.ago.to_date

    import = PdfImport.create_from_statement!(statement: create_pdf_statement(account: account))
    import.update!(
      document_type: "bank_statement",
      extracted_data: {
        "opening_balance" => 1000.00,
        "period" => { "start_date" => period_start.to_s }
      }
    )

    Import::Row.create!(
      import: import,
      source_row_number: 1,
      date: (period_start + 1.day).strftime(import.date_format),
      amount: "-20.00",
      name: "Test Deposit",
      currency: "USD"
    )
    import.rows.reset

    import.import!

    account.reload
    assert account.has_opening_anchor?
    assert_equal 1000.00, account.opening_anchor_balance.to_f
    assert_equal period_start - 1.day, account.opening_anchor_date
  end

  test "import! does not backfill opening balance when earlier entries already exist" do
    account = accounts(:depository)
    # The fixture account already has entries from several days ago, so a
    # statement period starting more recently than those must not backfill
    # an opening anchor over real, earlier data.
    period_start = Date.current

    import = PdfImport.create_from_statement!(statement: create_pdf_statement(account: account))
    import.update!(
      document_type: "bank_statement",
      extracted_data: {
        "opening_balance" => 1000.00,
        "period" => { "start_date" => period_start.to_s }
      }
    )

    Import::Row.create!(
      import: import,
      source_row_number: 1,
      date: period_start.strftime(import.date_format),
      amount: "-20.00",
      name: "Test Deposit",
      currency: "USD"
    )
    import.rows.reset

    import.import!

    assert_not account.reload.has_opening_anchor?
  end

  test "import! leaves investment_activity_label nil on non-investment accounts" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement(account: accounts(:depository)))
    import.update!(document_type: "bank_statement")

    Import::Row.create!(
      import: import,
      source_row_number: 1,
      date: Date.current.strftime(import.date_format),
      amount: "-5.50",
      name: "Coffee Shop",
      currency: "USD"
    )
    import.rows.reset

    import.import!

    entry = import.account.entries.find_by!(name: "Coffee Shop")
    assert_nil entry.entryable.investment_activity_label
  end

  test "process_with_ai_later enqueues ProcessPdfJob" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_with job: ProcessPdfJob, args: [ import ] do
      assert import.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not enqueue duplicate jobs while importing" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)

    assert_enqueued_jobs 1, only: ProcessPdfJob do
      assert import.process_with_ai_later
      assert_not import.reload.process_with_ai_later
    end

    assert_equal "importing", import.reload.status
  end

  test "process_with_ai_later does not claim import without pdf content" do
    assert_no_enqueued_jobs only: ProcessPdfJob do
      assert_not @import.process_with_ai_later
    end

    assert_equal "pending", @import.reload.status
  end

  test "process_with_ai_later resets pending when enqueue fails" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement)
    ProcessPdfJob.stubs(:perform_later).raises(StandardError, "queue offline")

    assert_not import.process_with_ai_later
    assert_equal "pending", import.reload.status
  end

  test "display_phase reflects queued, ready for review, and nothing-to-import states" do
    assert_equal :queued, @import.display_phase
    assert_equal :ready_for_review, @import_with_rows.display_phase
    assert_equal :complete, @processed_import.display_phase
  end

  test "display_phase distinguishes analyzing from publishing while importing" do
    @import.update!(status: :importing, processing_started_at: Time.current)
    assert_equal :analyzing, @import.display_phase

    @import.update!(ai_summary: "Some AI summary")
    assert_equal :publishing, @import.display_phase
  end

  test "display_phase flags a stalled record: AI finished but never advanced past pending" do
    @import.update!(ai_summary: "Some AI summary", rows_count: 0)
    assert_equal :stalled_after_processing, @import.display_phase
  end

  test "display_phase is imported once the import actually created entries" do
    import = PdfImport.create_from_statement!(statement: create_pdf_statement(account: accounts(:depository)))
    import.update!(document_type: "bank_statement", status: :complete)

    Import::Row.create!(
      import: import,
      source_row_number: 1,
      date: Date.current.strftime(import.date_format),
      amount: "-5.50",
      name: "Coffee Shop",
      currency: "USD"
    )
    import.rows.reset
    import.import!

    assert_equal :imported, import.reload.display_phase
  end

  test "display_phase is queued for an importing import the job has not started" do
    @import.update!(status: :importing, processing_started_at: nil)

    assert_equal :queued, @import.display_phase
  end

  test "queued_behind_count counts this family's unfinished imports queued earlier" do
    @import.update!(status: :importing)
    assert_equal 0, @import.queued_behind_count

    earlier = @import.family.imports.create!(type: "PdfImport", status: :importing)
    earlier.update_columns(status: "importing", created_at: @import.created_at - 1.minute)
    later = @import.family.imports.create!(type: "PdfImport", status: :importing)
    later.update_columns(status: "importing", created_at: @import.created_at + 1.minute)
    elsewhere = families(:empty).imports.create!(type: "PdfImport", status: :importing)
    elsewhere.update_columns(created_at: @import.created_at - 1.minute)

    assert_equal 1, @import.queued_behind_count
  end

  test "queued_behind_count is zero outside the queued phase" do
    @import_with_rows.update!(status: :importing)
    assert_equal 0, @import_with_rows.queued_behind_count
  end

  test "generate_rows_from_extracted_data creates import rows" do
    import = imports(:pdf_with_rows)
    import.rows.destroy_all
    import.update_column(:rows_count, 0)

    import.generate_rows_from_extracted_data

    assert_equal 2, import.rows.count
    assert_equal 2, import.rows_count

    coffee_row = import.rows.find_by(name: "Coffee Shop")
    assert_not_nil coffee_row
    assert_equal "-50.0", coffee_row.amount
    assert_equal "Food & Drink", coffee_row.category

    salary_row = import.rows.find_by(name: "Salary")
    assert_not_nil salary_row
    assert_equal "1500.0", salary_row.amount
  end

  test "generate_rows_from_extracted_data does nothing without extracted transactions" do
    @import.generate_rows_from_extracted_data
    assert_equal 0, @import.rows.count
  end

  test "extracted_transactions returns transactions from extracted_data" do
    assert_equal 2, @import_with_rows.extracted_transactions.size
    assert_equal "Coffee Shop", @import_with_rows.extracted_transactions.first["name"]
  end

  test "extracted_transactions returns empty array when no data" do
    assert_equal [], @import.extracted_transactions
  end

  test "has_extracted_transactions? returns true with transactions" do
    assert @import_with_rows.has_extracted_transactions?
  end

  test "has_extracted_transactions? returns false without transactions" do
    assert_not @import.has_extracted_transactions?
  end

  test "mapping_steps is empty when no categories in rows" do
    # PDF imports use direct account selection in UI, not AccountMapping
    assert_equal [], @import.mapping_steps
  end

  test "mapping_steps includes CategoryMapping when rows have categories" do
    @import_with_rows.rows.create!(
      source_row_number: 1,
      date: "01/15/2024",
      amount: -50.00,
      currency: "USD",
      name: "Test Transaction",
      category: "Groceries"
    )
    assert_equal [ Import::CategoryMapping ], @import_with_rows.mapping_steps
  end

  test "mapping_steps does not include AccountMapping even when account is nil" do
    # PDF imports handle account selection via direct UI, not mapping system
    assert_nil @import.account
    assert_not_includes @import.mapping_steps, Import::AccountMapping
  end

  test "suggested_account matches a candidate whose name contains the detected account number" do
    accounts(:depository).update!(name: "Checking (1234)")
    accounts(:credit_card).update!(name: "Card (5678)")
    @import.update!(extracted_data: { "account_number" => "1234" })

    assert_equal accounts(:depository), @import.suggested_account([ accounts(:depository), accounts(:credit_card) ])
  end

  test "suggested_account returns nil without a detected account number" do
    accounts(:depository).update!(name: "Checking (1234)")
    @import.update!(extracted_data: {})

    assert_nil @import.suggested_account([ accounts(:depository) ])
  end

  test "suggested_account returns nil once an account is already assigned" do
    accounts(:depository).update!(name: "Checking (1234)")
    @import.update!(account: accounts(:depository), extracted_data: { "account_number" => "1234" })

    assert_nil @import.suggested_account([ accounts(:depository) ])
  end

  test "suggested_account returns nil when more than one candidate matches" do
    accounts(:depository).update!(name: "Checking (1234)")
    accounts(:credit_card).update!(name: "Old Checking (1234)")
    @import.update!(extracted_data: { "account_number" => "1234" })

    assert_nil @import.suggested_account([ accounts(:depository), accounts(:credit_card) ])
  end

  test "detected_account_summary builds from whichever fields are present" do
    @import.update!(extracted_data: { "bank_name" => "Ally Bank", "account_number" => "6654", "account_holder" => "BRIAN RIDINGS" })
    assert_equal "Ally Bank • ····6654 • BRIAN RIDINGS", @import.detected_account_summary

    @import.update!(extracted_data: { "account_number" => "6654" })
    assert_equal "····6654", @import.detected_account_summary

    @import.update!(extracted_data: {})
    assert_nil @import.detected_account_summary
  end

  test "destroying import purges attached pdf_file" do
    @import.pdf_file.attach(
      io: StringIO.new("fake-pdf-content"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )

    attachment_id = @import.pdf_file.id
    assert ActiveStorage::Attachment.exists?(attachment_id)

    perform_enqueued_jobs do
      @import.destroy!
    end

    assert_not ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "destroying statement backed import keeps statement file" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    attachment_id = statement.original_file.id

    perform_enqueued_jobs do
      import.destroy!
    end

    assert ActiveStorage::Attachment.exists?(attachment_id)
  end

  test "statement backed import prevents source statement destroy" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)

    assert_no_difference "AccountStatement.count" do
      assert_not statement.destroy
    end

    assert_equal statement, import.reload.account_statement
  end

  test "statement backed import memoizes pdf content" do
    statement = create_pdf_statement
    import = PdfImport.create_from_statement!(statement: statement)
    statement.original_file.expects(:download).once.returns("%PDF-test")

    assert_equal "%PDF-test", import.pdf_file_content
    assert_equal "%PDF-test", import.pdf_file_content
  end

  test "statement backed import reuse requires current account and date format" do
    statement = create_pdf_statement
    stale_import = PdfImport.create_from_statement!(statement: statement)
    formats = Family::DATE_FORMATS.map(&:last)
    alternate_date_format = (formats - [ statement.family.date_format ]).first || "#{statement.family.date_format}-alternate"
    stale_import.update!(account: nil, date_format: alternate_date_format)

    fresh_import = PdfImport.create_from_statement!(statement: statement)

    assert_not_equal stale_import, fresh_import
    assert_equal statement.account, fresh_import.account
    assert_equal statement.family.date_format, fresh_import.date_format
  end

  test "statement backed import reuses matching reusable import" do
    statement = create_pdf_statement
    existing_import = PdfImport.create_from_statement!(statement: statement)

    assert_equal existing_import, PdfImport.create_from_statement!(statement: statement)
  end

  test "assigning account links statement backed import statement" do
    statement = create_pdf_statement(account: nil)
    import = PdfImport.create_from_statement!(statement: statement)
    account = accounts(:depository)

    import.assign_account!(account)

    assert_equal account, import.reload.account
    assert_equal account, statement.reload.account
    assert statement.linked?
  end

  test "assign_account! backfills opening balance even when nothing was extracted" do
    account = accounts(:depository)
    period_start = 10.days.ago.to_date

    statement = create_pdf_statement(account: nil)
    import = PdfImport.create_from_statement!(statement: statement)
    import.update!(
      document_type: "bank_statement",
      extracted_data: {
        "transactions" => [],
        "opening_balance" => 500.00,
        "period" => { "start_date" => period_start.to_s }
      }
    )

    assert import.assign_account!(account)

    account.reload
    assert account.has_opening_anchor?
    assert_equal 500.00, account.opening_anchor_balance.to_f
    assert_equal period_start - 1.day, account.opening_anchor_date
  end

  test "statement backed import requires pdf statement" do
    csv_statement = AccountStatement.create_from_upload!(
      family: @import.family,
      account: nil,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    import = PdfImport.new(family: @import.family, account_statement: csv_statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  test "statement backed import requires statement from same family" do
    statement = AccountStatement.create_from_upload!(
      family: families(:empty),
      account: nil,
      file: uploaded_file(
        filename: "other_family_statement.pdf",
        content_type: "application/pdf",
        content: file_fixture("imports/sample_bank_statement.pdf").binread
      )
    )
    import = PdfImport.new(family: @import.family, account_statement: statement)

    assert_not import.valid?
    assert import.errors[:account_statement].present?
  end

  private

    def create_pdf_statement(account: accounts(:depository))
      AccountStatement.create_from_upload!(
        family: @import.family,
        account: account,
        file: uploaded_file(
          filename: "sample_bank_statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
