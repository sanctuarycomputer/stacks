ActiveAdmin.register_page "Ghost Sync" do
  menu label: "Ghost Sync", parent: "Contacts"

  content title: "Ghost Sync" do
    # These locals must stay at the very top of this block, above every panel
    # that reads them. Ruby resolves block locals lexically at parse time, so a
    # panel block appearing above this assignment cannot see `map`/`newsletters`/
    # `prefixes`/`system` as locals and instead parses (e.g.) `map[...]` as a
    # method call, raising on every render. `ruby -c` cannot catch this.
    system = System.first_or_create!(settings: {})
    map = system.ghost_newsletter_prefix_map_clean
    newsletters_ok = true
    newsletters = begin
      Stacks::Ghost.new(max_retries: 1).all_newsletters.select { |n| n["status"] != "archived" }
    rescue => e
      newsletters_ok = false
      []
    end

    prefixes = Contact.connection.select_rows(<<~SQL).to_h
      SELECT src_prefix, COUNT(*) FROM (
        SELECT DISTINCT contacts.id, split_part(lower(s.source), ':', 1) AS src_prefix
        FROM contacts, LATERAL unnest(sources) AS s(source)
        WHERE lower(s.source) <> 'g3d:ghost' AND lower(s.source) NOT LIKE 'g3d:ghost:%'
      ) t GROUP BY src_prefix ORDER BY COUNT(*) DESC
    SQL

    sources_with_counts_raw = Contact.connection.select_rows(<<~SQL)
      SELECT s.source, COUNT(*)
      FROM contacts, LATERAL unnest(sources) AS s(source)
      GROUP BY s.source
      ORDER BY COUNT(*) DESC, s.source
    SQL
    enabled = system.ghost_synced_sources

    # Union enabled sources that have no contacts so they stay visible in the UI
    # and aren't silently destroyed on the next save.
    counts_by_source = sources_with_counts_raw.to_h
    enabled.each { |s| counts_by_source[s] ||= 0 }
    sources_with_counts = counts_by_source.sort_by { |s, c| [-c, s] }.map { |s, c| [s, c] }

    panel "Newsletter Mapping" do
      para "Each source prefix maps to one Ghost newsletter. Contacts with a source " \
           "under that prefix are subscribed to it once, and never re-subscribed if " \
           "they later unsubscribe. Do not map etl: it records Google Meet attendance, " \
           "not consent."
      # If Ghost is unreachable every dropdown renders with only "Not mapped", nothing
      # matches `selected:`, and submitting would post a blank for every prefix, deleting
      # the entire consent mapping. Refuse to render a submittable form in that state.
      if !newsletters_ok && map.any?
        para "Could not reach Ghost, so the newsletter list is unavailable. Saving is " \
             "disabled to avoid clearing the existing mapping. Reload once Ghost is reachable."
      end

      form action: admin_ghost_sync_update_newsletter_settings_path, method: :post do
        input type: :hidden, name: :authenticity_token, value: form_authenticity_token
        # Tells the page_action whether the dropdowns above were populated from a real
        # newsletter list. A submission that empties the map is only ever the accidental
        # "Ghost was unreachable" case when this is "0" -- a deliberate unmap (n=1, list
        # rendered fine) must still be allowed through.
        input type: :hidden, name: :newsletters_ok, value: newsletters_ok ? "1" : "0"
        table_for prefixes.to_a do
          column("Prefix") { |(prefix, _)| prefix }
          column("Contacts") { |(_, count)| count }
          column("Newsletter") do |(prefix, _)|
            select name: "prefix_map[#{prefix}]" do
              option "Not mapped", value: ""
              newsletters.map do |n|
                option n["name"], value: n["id"], selected: (map[prefix] == n["id"]) || nil
              end
            end
          end
          column("May subscribe") do |(prefix, _)|
            id = map[prefix]
            next "" if id.blank?
            # split_part matches Stacks::GhostSync.source_prefix exactly. A LIKE
            # '<prefix>:%' would miss a bare single-segment source such as `team`, which
            # the sweep WOULD subscribe, so the preview would understate the number
            # rollout step 3 asks Hugh to decide on.
            #
            # The matching source itself must be enabled, not merely some source on the
            # contact: target_newsletter_ids only ever derives newsletters from
            # (contact.sources & enabled), so a contact with an enabled `team` source and
            # a DISABLED `index:...` source is never subscribed under `index`. Constrain
            # the EXISTS to enabled sources so the panel cannot overstate what the sweep
            # will actually do.
            Contact
              .where("EXISTS (SELECT 1 FROM unnest(sources) s WHERE s = ANY(ARRAY[?]::varchar[]) AND split_part(lower(s), ':', 1) = ? AND lower(s) <> 'g3d:ghost' AND lower(s) NOT LIKE 'g3d:ghost:%')", enabled, prefix)
              .where("NOT jsonb_exists(COALESCE(ghost_data->'newsletter_ledger'->'entries', '{}'::jsonb), ?)", id)
              .count
          end
        end

        div style: "margin-top: 12px" do
          input type: :hidden, name: "grants_enabled", value: "0"
          input type: :checkbox, name: "grants_enabled", value: "1",
            checked: system.ghost_newsletter_grants_enabled? || nil
          span "Apply grants to existing members. Leave off for a dry run."
        end
        div style: "margin-top: 8px" do
          span "Writes per sweep: "
          input type: :number, name: "write_budget", min: 1,
            value: system.ghost_sweep_write_budget_clamped
        end
        div style: "margin-top: 12px" do
          input type: :submit, value: "Save Newsletter Settings",
            disabled: (!newsletters_ok && map.any?) || nil
        end
      end
    end

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
          column("Newsletter") do |(source, _count)|
            id = map[source.to_s.split(":", 2).first.to_s.downcase]
            id.present? ? (newsletters.find { |n| n["id"] == id }&.dig("name") || id)
                        : "No newsletter (members created with no subscription)"
          end
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

    panel "Last Sweep Summary" do
      summary = system.ghost_last_sync_summary
      if summary.blank?
        para "No sweep has recorded a summary yet."
      else
        table_for summary.to_a do
          column("Counter") { |(k, _)| k }
          column("Value") { |(_, v)| v.is_a?(Hash) ? v.inspect : v }
        end
      end
    end
  end

  page_action :update_sources, method: :post do
    checked = Array(params[:sources]).map(&:to_s).reject(&:blank?)
    System.first_or_create!(settings: {}).update!(ghost_synced_sources: checked)
    redirect_to admin_ghost_sync_path, notice: "Synced sources updated (#{checked.length} enabled)"
  end

  page_action :update_newsletter_settings, method: :post do
    # The default must be Parameters, not Hash: a plain {} has no #permit! and would
    # raise when no prefix rows are submitted.
    submitted = params[:prefix_map] || ActionController::Parameters.new
    map = submitted.permit!.to_h
      .transform_keys { |k| k.to_s.downcase }
      .transform_values(&:to_s)
      .reject { |_, v| v.blank? }

    # Only "0" (explicitly posted by the page when the newsletter list failed to load)
    # counts as unreachable; a missing/garbled value is treated as a real render so a
    # deliberate clear is never silently refused.
    newsletters_ok = params[:newsletters_ok] != "0"

    system = System.first_or_create!(settings: {})
    if map.empty? && !newsletters_ok && system.ghost_newsletter_prefix_map_clean.any?
      redirect_to admin_ghost_sync_path,
        alert: "Ghost was unreachable when this page loaded, so every dropdown defaulted " \
               "to \"Not mapped\". Refusing to save an empty mapping. Reload once Ghost is " \
               "reachable and try again."
      return
    end

    system.update!(
      ghost_newsletter_prefix_map: map,
      ghost_newsletter_grants_enabled: ActiveModel::Type::Boolean.new.cast(params[:grants_enabled]) || false,
      ghost_sweep_write_budget: [params[:write_budget].presence.to_i, 1].max,
    )
    redirect_to admin_ghost_sync_path, notice: "Newsletter settings updated (#{map.length} prefixes mapped)"
  end

  page_action :sync_now, method: :post do
    sync = Stacks::GhostSync.sync_all_with_lock!(Stacks::Ghost.new(max_retries: 1))
    if sync
      notice = "Ghost sync complete: #{sync.summary.to_h.inspect}"
      notice += " -- first error: #{sync.errors.first}" if sync.errors.any?
      redirect_to admin_ghost_sync_path, notice: notice
    else
      redirect_to admin_ghost_sync_path, alert: "A Ghost sync is already running -- try again shortly."
    end
  end
end
