ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'
require 'mocha/minitest'
require 'minitest/autorun'

# Ensure DB triggers that schema.rb cannot capture are present in the test DB.
# The ScopeQboRecordsByQboAccount migration installs a BEFORE DELETE trigger on
# qbo_invoices that nullifies qbo_invoice_id on child tables (invoice_trackers,
# contributor_adjustments, adhoc_invoice_trackers). schema.rb format cannot dump
# triggers, so we recreate it here idempotently.
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE OR REPLACE FUNCTION nullify_qbo_invoice_id_on_children()
  RETURNS trigger AS $body$
  BEGIN
    UPDATE invoice_trackers SET qbo_invoice_id = NULL
      WHERE qbo_account_id = OLD.qbo_account_id AND qbo_invoice_id = OLD.qbo_id;
    UPDATE contributor_adjustments SET qbo_invoice_id = NULL
      WHERE qbo_account_id = OLD.qbo_account_id AND qbo_invoice_id = OLD.qbo_id;
    UPDATE adhoc_invoice_trackers SET qbo_invoice_id = NULL
      WHERE qbo_account_id = OLD.qbo_account_id AND qbo_invoice_id = OLD.qbo_id;
    RETURN OLD;
  END;
  $body$ LANGUAGE plpgsql;

  DROP TRIGGER IF EXISTS trg_qbo_invoices_nullify_children ON qbo_invoices;
  CREATE TRIGGER trg_qbo_invoices_nullify_children
    BEFORE DELETE ON qbo_invoices
    FOR EACH ROW
    EXECUTE FUNCTION nullify_qbo_invoice_id_on_children();
SQL

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...

  def make_studio!
    tb = Studio.create!({
      name: "Thoughtbot",
      accounting_prefix: "Development",
      mini_name: "tb",
      snapshot: {}
    })

    g3d = Studio.create!({
      name: "garden3d",
      accounting_prefix: "",
      mini_name: "g3d",
      snapshot: {}
    })

    [tb, g3d]
  end

  def make_admin_user!(studio, started_at, ended_at = nil, email = "chad@thoughtbot.com")
    admin_user = AdminUser.create!({
      email: email,
      password: "password",
      old_skill_tree_level: :lead_2
    })

    person_one = ForecastPerson.create!({
      forecast_id: AdminUser.count + 1,
      roles: [studio.name],
      email: admin_user.email
    })

    FullTimePeriod.create!({
      admin_user: admin_user,
      started_at: started_at,
      ended_at: ended_at,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    StudioMembership.create!({
      studio: studio,
      admin_user: admin_user,
      started_at: started_at
    })

    admin_user.reload
  end

  def make_forecast_project!(client_name = "US Government", project_name = "Healthcare.gov")
    forecast_client = ForecastClient.create!({
      forecast_id: ForecastClient.count + 1,
      name: client_name
    })

    forecast_project = ForecastProject.create!({
      forecast_id: ForecastProject.count + 1,
      name: project_name,
      forecast_client: forecast_client,
      code: "#{project_name} #{ForecastProject.count + 1}",
    })

    [forecast_project, forecast_client]
  end

  def make_project_tracker!(forecast_projects)
    project_tracker_links = [
      ProjectTrackerLink.new({
        name: "SOW link",
        url: "https://example.com",
        link_type: "sow"
      }),
      ProjectTrackerLink.new({
        name: "MSA link",
        url: "https://example.com",
        link_type: "msa"
      })
    ]

    tracker = ProjectTracker.create!({
      name: "Healthcare.gov Project Tracker",
      forecast_projects: forecast_projects,
      project_tracker_links: project_tracker_links
    })
  end
end
