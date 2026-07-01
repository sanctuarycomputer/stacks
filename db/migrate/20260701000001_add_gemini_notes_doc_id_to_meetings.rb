class AddGeminiNotesDocIdToMeetings < ActiveRecord::Migration[6.1]
  def change
    add_column :meetings, :gemini_notes_doc_id, :string
    add_index :meetings, :gemini_notes_doc_id, unique: true,
              where: "gemini_notes_doc_id IS NOT NULL",
              name: "index_meetings_on_gemini_notes_doc_id"
  end
end
