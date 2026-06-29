class AddDriveDocIdIndexToDocuments < ActiveRecord::Migration[6.1]
  def change
    # The Drive<->API dedup looks up `raw_metadata->>'drive_doc_id'` once per Drive file
    # during the org-wide backfill (thousands of files). Index the expression so that
    # lookup doesn't seq-scan the growing documents table on every transcript.
    add_index :documents, "(raw_metadata->>'drive_doc_id')", name: 'index_documents_on_drive_doc_id'
  end
end
