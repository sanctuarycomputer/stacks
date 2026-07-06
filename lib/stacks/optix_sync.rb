# Pulls Optix data into the local DB. One instance per OptixOrganization;
# keeps everything scoped to that org so a future second tenant doesn't bleed
# into the first.
#
# Usage:
#   Stacks::OptixSync.new(OptixOrganization.first).sync_all!
#
# Per-table sync methods are individually callable for partial syncs / debugging.
class Stacks::OptixSync
  attr_reader :optix_organization, :client

  def initialize(optix_organization)
    @optix_organization = optix_organization
    @client = optix_organization.client
  end

  # Run every sync in order. Order matters because account_plans references
  # plan_templates, and plan_templates → locations via the join table.
  def sync_all!
    sync_locations!
    sync_plan_templates!
    sync_users!
    sync_account_plans!
    optix_organization.update!(synced_at: Time.current)
    self
  end

  # ---------- per-table syncs ----------

  def sync_locations!
    rows = client.list_locations.map { |loc|
      {
        optix_id:                loc["location_id"],
        optix_organization_id:   optix_organization.id,
        name:                    loc["name"],
        city:                    loc["city"],
        region:                  loc["region"],
        country:                 loc["country"],
        timezone:                loc["timezone"],
        is_visible:              loc["is_visible"]  != false,
        is_hidden:               loc["is_hidden"]   == true,
        is_deleted:              loc["is_deleted"]  == true,
        data:                    loc,
        synced_at:               now,
        created_at:              now,
        updated_at:              now,
      }
    }
    upsert(OptixLocation, rows)
  end

  def sync_plan_templates!
    templates = client.list_plan_templates

    # Upsert templates first.
    template_rows = templates.map { |t|
      {
        optix_id:               t["plan_template_id"],
        optix_organization_id:  optix_organization.id,
        name:                   t["name"],
        price:                  t["price"],
        price_frequency:        t["price_frequency"],
        in_all_locations:       t["in_all_locations"] == true,
        onboarding_enabled:     t["onboarding_enabled"]     != false,
        non_onboarding_enabled: t["non_onboarding_enabled"] != false,
        data:                   t,
        synced_at:              now,
        created_at:              now,
        updated_at:              now,
      }
    }
    upsert(OptixPlanTemplate, template_rows)

    # Refresh the join table (plan_template ↔ location). Easiest correct path:
    # delete-and-recreate per template.
    OptixPlanTemplate.where(optix_organization_id: optix_organization.id).find_in_batches do |batch|
      OptixPlanTemplateLocation
        .where(optix_plan_template_id: batch.map(&:optix_id))
        .delete_all
    end

    join_rows = templates.flat_map { |t|
      (t["locations"] || []).map { |loc|
        {
          optix_plan_template_id: t["plan_template_id"],
          optix_location_id:      loc["location_id"],
          created_at:             now,
          updated_at:              now,
        }
      }
    }
    OptixPlanTemplateLocation.upsert_all(join_rows) if join_rows.any?
  end

  def sync_users!
    rows = client.list_users.map { |u|
      {
        optix_id:               u["user_id"],
        optix_organization_id:  optix_organization.id,
        email:                  u["email"],
        name:                   u["name"],
        # Optix names the field `surname`; we store it in `last_name` column.
        # `first_name` and `created_timestamp` aren't exposed on User in this
        # Optix tenant — columns stay nullable in the DB until we have a source.
        last_name:              u["surname"],
        is_active:              u["is_active"] != false,
        data:                   u,
        synced_at:              now,
        created_at:             now,
        updated_at:             now,
      }
    }
    upsert(OptixUser, rows)
  end

  def sync_account_plans!
    rows = client.list_account_plans(status: nil).map { |plan|
      access_usage_user_id = plan.dig("access_usage_user", "user_id")

      {
        optix_id:                       plan["account_plan_id"],
        optix_organization_id:          optix_organization.id,
        optix_plan_template_id:         plan.dig("plan_template", "plan_template_id"),
        name:                           plan["name"],
        status:                         plan["status"],
        price:                          plan["price"],
        price_frequency:                plan["price_frequency"],
        start_timestamp:                plan["start_timestamp"],
        end_timestamp:                  plan["end_timestamp"],
        canceled_timestamp:             plan["canceled_timestamp"],
        created_timestamp:              plan["created_timestamp"],
        access_usage_user_optix_id:     access_usage_user_id,
        data:                           plan,
        synced_at:                      now,
        created_at:                     now,
        updated_at:                     now,
      }
    }
    upsert(OptixAccountPlan, rows)
  end

  private

  def now
    @now ||= Time.current
  end

  # Upsert by primary key (optix_id) for the optix_* tables. On Rails 6.1
  # `upsert_all` updates every supplied column on conflict — including
  # `created_at`, which is cosmetically lossy but functionally fine. If we
  # ever need to preserve the original creation timestamp through repeat
  # syncs, the path is to drop `created_at` from `rows` and rely on
  # `record_timestamps: true`, but that requires Rails 7's nuanced handling.
  def upsert(model, rows)
    return if rows.empty?
    model.upsert_all(rows, unique_by: :optix_id)
  end
end
