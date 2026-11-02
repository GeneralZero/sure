# When ProcessPdfJob actually began working on an import, as opposed to
# merely queueing it: queued imports are already `importing`, so status alone
# cannot tell a statement waiting its turn from the one being read.
class AddProcessingStartedAtToImports < ActiveRecord::Migration[8.1]
  def change
    add_column :imports, :processing_started_at, :datetime
  end
end
