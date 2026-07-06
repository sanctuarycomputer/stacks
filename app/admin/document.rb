ActiveAdmin.register Document do
  menu parent: 'MCP', label: 'ETL: Documents', if: proc { current_admin_user&.can_access_etl_admin? }
  actions :index, :show

  # Only Hugh can reach these pages — blocks direct URL navigation, not just the menu.
  controller do
    before_action do
      unless current_admin_user&.can_access_etl_admin?
        redirect_to admin_root_path, alert: "You are not authorized to view that page."
      end
    end
  end

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

  # Re-include a previously-excluded document and index it from its STORED transcript
  # segments (no Google re-fetch) so it becomes searchable by the agent.
  member_action :include_and_index, method: :put do
    resource.update!(excluded: :manually_included, excluded_reason: :none, excluded_by: current_admin_user.email)
    indexed = Stacks::Etl::Reindexer.call(resource)
    notice = indexed ? "Included & indexed (#{resource.chunks.count} chunks)." : 'Included (no stored segments to index).'
    redirect_to admin_document_path(resource), notice: notice
  end

  # Exclude a document: wall it off from the agent and drop its chunks/embeddings
  # (the raw Meeting + transcript segments are retained, so this is reversible).
  member_action :exclude, method: :put do
    resource.update!(excluded: :manually_excluded, excluded_reason: :manual, excluded_by: current_admin_user.email)
    resource.chunks.destroy_all
    redirect_to admin_document_path(resource), notice: 'Excluded (chunks removed; transcript retained).'
  end

  action_item :include_and_index, only: :show, if: proc { !resource.corpus_eligible? } do
    link_to 'Include & index', include_and_index_admin_document_path(resource), method: :put
  end

  action_item :exclude, only: :show, if: proc { resource.corpus_eligible? } do
    link_to 'Exclude', exclude_admin_document_path(resource), method: :put
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
