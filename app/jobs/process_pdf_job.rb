class ProcessPdfJob < ApplicationJob
  queue_as :ai_low_priority

  discard_on(Provider::Error) do |job, err|
    Rails.logger.error("[ProcessPdfJob] Discarded permanently (job_id=#{job.job_id}, error_class=#{err.class.name})")
  end

  # Stable across deploys so old and new workers serialize on the same lock.
  PROCESSING_LOCK_KEY = Digest::MD5.hexdigest("process_pdf_job").to_i(16) % (2**62)

  def perform(pdf_import)
    return unless pdf_import.is_a?(PdfImport)

    return reset_processing_claim(pdf_import) unless pdf_import.pdf_uploaded?
    return if pdf_import.status.in?(%w[complete failed])
    return reset_processing_claim(pdf_import) if pdf_import.ai_processed? && (!pdf_import.statement_with_transactions? || pdf_import.rows_count > 0)

    # One import at a time, app-wide: a single local, CPU-bound model gains
    # nothing from concurrent requests and ties up a worker thread per job for
    # hours. Every queued import is already `importing`, so the gate is a
    # session advisory lock rather than a status check, which Postgres also
    # releases if the worker dies. A fresh perform_later (not retry_job) so
    # waiting behind a slow statement never counts toward retry exhaustion.
    acquired = with_processing_lock { process(pdf_import) }
    self.class.set(wait: 1.minute).perform_later(pdf_import) unless acquired
  end

  private

    def with_processing_lock
      connection = ActiveRecord::Base.connection
      acquired = connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", PROCESSING_LOCK_KEY ]))
      return false unless acquired

      begin
        yield
      ensure
        connection.execute(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", PROCESSING_LOCK_KEY ]))
      end
      true
    end

    def process(pdf_import)
      pdf_import.update!(status: :importing, processing_started_at: Time.current)

      process_result = pdf_import.process_with_ai
      document_type = resolve_document_type(pdf_import, process_result)
      upload_to_vector_store(pdf_import, document_type: document_type)

      # For statements with transactions (bank/credit card), extract and generate import rows
      if statement_with_transactions?(document_type)
        Rails.logger.info("ProcessPdfJob: Extracting transactions for #{document_type} import #{pdf_import.id}")
        pdf_import.extract_transactions
        Rails.logger.info("ProcessPdfJob: Extracted #{pdf_import.extracted_transactions.size} transactions")

        pdf_import.generate_rows_from_extracted_data
        pdf_import.sync_mappings
        Rails.logger.info("ProcessPdfJob: Generated #{pdf_import.rows_count} import rows")
      end

      # Find the user who created this import (first admin or any user in the family)
      user = pdf_import.family.users.find_by(role: :admin) || pdf_import.family.users.first

      if user
        pdf_import.send_next_steps_email(user)
      end

      # Statements with extracted rows go to pending for user review/publish
      # Other document types are marked complete (no further action needed)
      final_status = statement_with_transactions?(document_type) && pdf_import.rows_count > 0 ? :pending : :complete
      pdf_import.update!(status: final_status, processing_started_at: nil)
    rescue StandardError => e
      sanitized_error = sanitize_error_message(e)
      Rails.logger.error("PDF processing failed for import #{pdf_import.id}: #{e.class.name} - #{sanitized_error}")
      begin
        pdf_import.update!(status: :failed, error: sanitized_error, processing_started_at: nil)
      rescue StandardError => update_error
        Rails.logger.error("Failed to update import status: #{update_error.message}")
      end
      raise
    end

    def sanitize_error_message(error)
      case error
      when Provider::Error, RuntimeError, ArgumentError
        I18n.t("imports.pdf_import.processing_failed_with_message",
               message: error.message.truncate(500))
      else
        I18n.t("imports.pdf_import.processing_failed_generic",
               error: error.class.name.demodulize)
      end
    end

    def upload_to_vector_store(pdf_import, document_type:)
      file_content = pdf_import.pdf_file_content

      family_document = pdf_import.family.upload_document(
        file_content: file_content,
        filename: pdf_import.pdf_filename,
        metadata: { "type" => document_type }
      )

      return if family_document

      Rails.logger.warn("ProcessPdfJob: Vector store upload failed for import #{pdf_import.id}")
    end

    def resolve_document_type(pdf_import, process_result)
      return process_result.document_type if process_result.respond_to?(:document_type) && process_result.document_type.present?

      pdf_import.reload.document_type
    end

    def statement_with_transactions?(document_type)
      document_type.in?(%w[bank_statement credit_card_statement investment_statement])
    end

    def reset_processing_claim(pdf_import)
      pdf_import.with_lock { pdf_import.update!(status: :pending, processing_started_at: nil) if pdf_import.importing? && pdf_import.updated_at <= 30.minutes.ago }
    end
end
