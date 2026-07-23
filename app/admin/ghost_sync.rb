ActiveAdmin.register_page "Ghost Sync" do
  menu label: "Ghost Sync"

  content title: "Ghost Sync" do
    sources_with_counts_raw = Contact.connection.select_rows(<<~SQL)
      SELECT s.source, COUNT(*)
      FROM contacts, LATERAL unnest(sources) AS s(source)
      GROUP BY s.source
      ORDER BY COUNT(*) DESC, s.source
    SQL
    enabled = System.instance.ghost_synced_sources

    # Union enabled sources that have no contacts so they stay visible in the UI
    # and aren't silently destroyed on the next save.
    counts_by_source = sources_with_counts_raw.to_h
    enabled.each { |s| counts_by_source[s] ||= 0 }
    sources_with_counts = counts_by_source.sort_by { |s, c| [-c, s] }.map { |s, c| [s, c] }

    panel "Synced Sources" do
      para "Contacts with a checked source are pushed to Ghost as members, " \
           "labeled with the source name verbatim. Unchecking a source stops " \
           "label management for it (existing labels stay in Ghost; members " \
           "are never deleted)."
      form action: admin_ghost_sync_update_sources_path, method: :post do
        input type: :hidden, name: :authenticity_token, value: form_authenticity_token
        table_for sources_with_counts do
          column("Sync?") do |(source, _count)|
            input type: :checkbox, name: "sources[]", value: source,
              checked: enabled.include?(source) || nil
          end
          column("Source") { |(source, _count)| source }
          column("Contacts") { |(_source, count)| count }
        end
        div style: "margin-top: 12px" do
          input type: :submit, value: "Save Synced Sources"
        end
      end
    end

    panel "Sync" do
      para "Runs once a day as part of stacks:daily_enterprise_tasks " \
           "(also available standalone as rake ghost:sync). Use Sync Now " \
           "for an immediate pass."
      form action: admin_ghost_sync_sync_now_path, method: :post do
        input type: :hidden, name: :authenticity_token, value: form_authenticity_token
        input type: :submit, value: "Sync Now"
      end
    end
  end

  page_action :update_sources, method: :post do
    checked = Array(params[:sources]).map(&:to_s).reject(&:blank?)
    System.instance.update!(ghost_synced_sources: checked)
    redirect_to admin_ghost_sync_path, notice: "Synced sources updated (#{checked.length} enabled)"
  end

  page_action :sync_now, method: :post do
    sync = Stacks::GhostSync.sync_all_with_lock!(Stacks::Ghost.new(max_retries: 1))
    if sync
      notice = "Ghost sync complete: #{sync.summary.to_h.inspect}"
      notice += " — first error: #{sync.errors.first}" if sync.errors.any?
      redirect_to admin_ghost_sync_path, notice: notice
    else
      redirect_to admin_ghost_sync_path, alert: "A Ghost sync is already running — try again shortly."
    end
  end
end
