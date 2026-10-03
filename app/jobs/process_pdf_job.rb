class ProcessPdfJob < ApplicationJob
  queue_as :ai_low_priority

  discard_on(Provider::Error) do |job, err|
    Rails.logger.error("[ProcessPdfJob] Discarded permanently (job_id=#{job.job_id}, error_class=#{err.class.name})")
  end

  def perform(pdf_import)
    return unless pdf_import.is_a?(PdfImport)

    # Sidekiq happily runs several of these concurrently, which is fine
    # against a cloud API but pointless and actively harmful against a
    # single local, CPU-bound model: concurrent requests to the same
    # one-model server don't run in parallel, they just contend for the same
    # compute and tie up multiple Sidekiq worker threads for hours at a
    # stretch each, starving every other background job (syncs,
    # categorization, etc.) in the meantime. This gate ensures at most one
    # PdfImport processes at a time app-wide, regardless of whether the
    # imports came from one bulk upload or scattered single uploads over
    # time.
    #
    # Deliberately a fresh perform_later (not retry_job): retry_job counts
    # against Sidekiq's retry-exhaustion limit, and a PDF waiting behind
    # several slow ones could need dozens of checks before its turn - that's
    # normal queueing, not a failing job, and must never land in the dead
    # set for it. A stuck `importing` claim doesn't deadlock this either:
    # reset_processing_claim below already reaps anything stuck past 30
    # minutes back to pending, which stops satisfying this gate on the very
    # next check.
    # A claim stuck past 30 minutes doesn't get reaped here (only
    # reset_processing_claim below does that, and only for this job's own
    # pdf_import) - without this staleness filter, any import left behind in
    # `importing` by a killed/crashed worker blocks every other import's gate
    # check forever, since none of them ever advances far enough to reap it.
    if PdfImport.where(status: :importing).where.not(id: pdf_import.id).where("updated_at > ?", 30.minutes.ago).exists?
      self.class.set(wait: 5.minutes).perform_later(pdf_import)
      return
    end

    return reset_processing_claim(pdf_import) unless pdf_import.pdf_uploaded?
    return if pdf_import.status.in?(%w[complete failed])
    return reset_processing_claim(pdf_import) if pdf_import.ai_processed? && (!pdf_import.statement_with_transactions? || pdf_import.rows_count > 0)

    pdf_import.update!(status: :importing)

    begin
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
      pdf_import.update!(status: final_status)
    rescue StandardError => e
      sanitized_error = sanitize_error_message(e)
      Rails.logger.error("PDF processing failed for import #{pdf_import.id}: #{e.class.name} - #{sanitized_error}")
      begin
        pdf_import.update!(status: :failed, error: sanitized_error)
      rescue StandardError => update_error
        Rails.logger.error("Failed to update import status: #{update_error.message}")
      end
      raise
    end
  end

  private

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
      pdf_import.with_lock { pdf_import.update!(status: :pending) if pdf_import.importing? && pdf_import.updated_at <= 30.minutes.ago }
    end
end
