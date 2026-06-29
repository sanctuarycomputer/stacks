ActiveAdmin.register Document do
  menu parent: 'MCP', label: 'ETL: Documents'
  actions :index, :show

  filter :source
  filter :excluded
  filter :occurred_at

  index do
    id_column
    column :source
    column :title
    column :occurred_at
    column :excluded
    column('Chunks') { |d| d.chunks.count }
    actions
  end

  show do
    attributes_table do
      row :source
      row :title
      row :url
      row :occurred_at
      row :excluded
      row :excluded_reason
      row :excluded_by
      row('Meeting') { |d| d.source_record.is_a?(Meeting) ? link_to(d.source_record.title, admin_meeting_path(d.source_record)) : nil }
    end

    panel "Chunks (#{resource.chunks.count})" do
      table_for resource.chunks.order(:position) do
        column(:position)
        column(:speaker_name)
        column(:speaker_contact)
        column(:content) { |c| truncate(c.content, length: 160) }
        column('') { |c| link_to 'View', admin_chunk_path(c) }
      end
    end

    panel 'Mentions' do
      mentions = Mention.where(chunk_id: resource.chunks.select(:id)).includes(:contact)
      table_for mentions.limit(100) do
        column(:raw_text)
        column(:status)
        column(:contact)
        column('') { |m| link_to 'View', admin_mention_path(m) }
      end
    end
  end
end
