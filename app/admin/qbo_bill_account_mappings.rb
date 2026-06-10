ActiveAdmin.register QboBillAccountMapping do
  menu label: "QBO Account Mappings", parent: "Money"
  actions :index, :show, :new, :create, :edit, :update, :destroy
  permit_params :enterprise_id, :line_item_key, :project_tracker_id, :contributor_id, :qbo_chart_account_qbo_id

  controller do
    # Supports prefilled "Add override" links from the Enterprise /
    # ProjectTracker / Contributor pages.
    def build_new_resource
      super.tap do |r|
        if params[:qbo_bill_account_mapping].present?
          r.assign_attributes(
            params.require(:qbo_bill_account_mapping)
              .permit(:enterprise_id, :line_item_key, :project_tracker_id, :contributor_id),
          )
        end
      end
    end
  end

  index download_links: false do
    column :enterprise
    column("Line item", :line_item_key)
    column("Subject") { |m| m.subject_label }
    column("QBO account") { |m| m.chart_account&.display_label || m.qbo_chart_account_qbo_id }
    actions
  end

  filter :enterprise
  filter :line_item_key, as: :select, collection: QboBillAccountMapping::LINE_ITEM_KEYS
  filter :project_tracker
  filter :contributor

  show do
    attributes_table do
      row :enterprise
      row :line_item_key
      row("Subject") { |m| m.subject_label }
      row("QBO account") { |m| m.chart_account&.display_label || m.qbo_chart_account_qbo_id }
      row :created_at
      row :updated_at
    end
  end

  form do |f|
    # When the enterprise is already known (edit, or prefilled new), scope
    # the chart-account options to its realm. qbo_ids are NOT unique across
    # realms, so the unscoped fallback prefixes each option with its
    # enterprise name — pick one matching the enterprise selected above
    # (validation rejects ids absent from the chosen enterprise's realm,
    # but cannot catch an id that exists in both realms).
    known_enterprise = f.object.enterprise
    chart_options =
      if known_enterprise&.qbo_account
        QboChartAccount.active
          .where(qbo_account_id: known_enterprise.qbo_account.id)
          .order(:name)
          .map { |a| [a.display_label, a.qbo_id] }
      else
        QboChartAccount.active
          .includes(qbo_account: :enterprise)
          .sort_by { |a| [a.qbo_account.enterprise&.name.to_s, a.name] }
          .map { |a| ["#{a.qbo_account.enterprise&.name} — #{a.display_label}", a.qbo_id] }
      end

    f.inputs(class: "admin_inputs") do
      f.semantic_errors
      f.input :enterprise, as: :select,
        collection: Enterprise.order(:name).pluck(:name, :id),
        include_blank: false
      f.input :line_item_key, as: :select,
        collection: QboBillAccountMapping::LINE_ITEM_KEYS,
        include_blank: false
      f.input :project_tracker_id, as: :select,
        collection: ProjectTracker.order(:name).pluck(:name, :id),
        include_blank: "(none — leave blank unless this is a project-tracker override)"
      f.input :contributor_id, as: :select,
        collection: Contributor.includes(:forecast_person).map { |c| [c.display_name, c.id] },
        include_blank: "(none — leave blank unless this is a contributor override)",
        hint: "Set a project tracker OR a contributor, not both. Both blank = entity-level default."
      f.input :qbo_chart_account_qbo_id, as: :select,
        collection: chart_options,
        include_blank: "Choose a QBO account…",
        label: "QBO chart account"
    end
    f.actions
  end
end
