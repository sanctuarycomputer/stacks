class AddDriveDocIdIndexToDocuments < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def change
    # The Drive<->API dedup looks up `raw_metadata->>'drive_doc_id'` once per Drive file
    # during the org-wide backfill (thousands of files). Index the expression so that
    # lookup doesn't seq-scan the growing documents table on every transcript. Built
    # CONCURRENTLY so it doesn't take an ACCESS EXCLUSIVE lock on documents while the
    # continuous Meet API sync is inserting (matches the repo's existing index pattern).
    add_index :documents, "(raw_metadata->>'drive_doc_id')",
              name: 'index_documents_on_drive_doc_id',
              algorithm: :concurrently,
              if_not_exists: true
  end
end
