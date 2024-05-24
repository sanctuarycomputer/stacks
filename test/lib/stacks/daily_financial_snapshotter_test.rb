require "test_helper"

class Stacks::DailyFinancialSnapshotterTest < ActiveSupport::TestCase
  test "#snapshot! builds the expected daily snapshots for an employee contributor" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
      old_skill_tree_level: :senior_3
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: [studio.name],
      email: user.email
    })

    FullTimePeriod.create!({
      admin_user: user,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new(start_date)
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: forecast_person.id,
        forecast_project_id: forecast_project.id,
        effective_date: start_date,
        studio_id: studio.id,
        hourly_cost: 68.25,
        hours: 8,
        needs_review: false
      }
    ])
  end

  test "#snapshot! builds the expected daily snapshots for a contractor using the notes specified on the Forecast project" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      notes: "subcontractor-1@some-other-agency.com:99.55p/h\nsubcontractor-2@some-other-agency.com:123p/h",
      start_date: start_date
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: ["Subcontractor", "Sanctuary Computer"],
      email: "subcontractor-2@some-other-agency.com"
    })

    ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new(start_date)
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: forecast_person.id,
        forecast_project_id: forecast_project.id,
        effective_date: start_date,
        studio_id: studio.id,
        hourly_cost: 123,
        hours: 8,
        needs_review: false
      }
    ])
  end

  test "#snapshot! deletes old snapshot records for the target day before inserting new ones" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: [studio.name],
      email: user.email
    })

    FullTimePeriod.create!({
      admin_user: user,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    forecast_assignment = ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    ForecastAssignmentDailyFinancialSnapshot.create!({
      forecast_assignment: forecast_assignment,
      forecast_person_id: forecast_person.id,
      forecast_project_id: forecast_project.id,
      effective_date: start_date,
      studio_id: studio.id,
      hourly_cost: 56.49,
      hours: 8,
      needs_review: false
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new(start_date)
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: forecast_person.id,
        forecast_project_id: forecast_project.id,
        effective_date: start_date,
        studio_id: studio.id,
        hourly_cost: 56.49,
        hours: 8,
        needs_review: false
      }
    ])
  end

  test "#snapshot! flags new snapshot records for review if their hourly cost could not be determined" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      # Notice: no cost overrides specified in notes field
      start_date: start_date
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: ["Subcontractor", "Sanctuary Computer"],
      email: "subcontractor@some-other-agency.com"
    })

    ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new(start_date)
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: forecast_person.id,
        forecast_project_id: forecast_project.id,
        effective_date: start_date,
        studio_id: studio.id,
        hourly_cost: 0,
        hours: 8,
        needs_review: true
      }
    ])
  end

  test "#snapshot! flags new snapshot records for review for employees without a studio" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: [],
      email: user.email
    })

    FullTimePeriod.create!({
      admin_user: user,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new(start_date, [])
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: forecast_person.id,
        forecast_project_id: forecast_project.id,
        effective_date: start_date,
        studio_id: 0,
        hourly_cost: 56.49,
        hours: 8,
        needs_review: true
      }
    ])
  end

  test "#snapshot! does not flag new snapshot records for review for subcontractors without a studio" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      notes: "subcontractor@some-other-agency.com:99.55p/h",
      start_date: start_date
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: ["Subcontractor", "Some non-identifiable studio"],
      email: "subcontractor@some-other-agency.com"
    })

    ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new(start_date, [studio])
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: forecast_person.id,
        forecast_project_id: forecast_project.id,
        effective_date: start_date,
        studio_id: 0,
        hourly_cost: 99.55,
        hours: 8,
        needs_review: false
      }
    ])
  end

  test "#snapshot! does not create snapshot records for assignment days without hours" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: [studio.name],
      email: user.email
    })

    FullTimePeriod.create!({
      admin_user: user,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project,
      allocation: 0
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new(start_date)
    snapshotter.snapshot!

    assert_snapshot_attributes([])
  end

  test "#snapshot! uses the current date as the effective date if no explicit date is supplied" do
    start_date = Date.today - 1.day
    end_date = Date.today + 1.day

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: 123,
      roles: [studio.name],
      email: user.email
    })

    FullTimePeriod.create!({
      admin_user: user,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    snapshotter = Stacks::DailyFinancialSnapshotter.new
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: forecast_person.id,
        forecast_project_id: forecast_project.id,
        effective_date: Date.today,
        studio_id: studio.id,
        hourly_cost: 56.49,
        hours: 8,
        needs_review: false
      }
    ])
  end

  test "#snapshot! with more complicated case, using multiple people and projects" do
    start_date = Date.today - 1.day
    end_date = Date.today + 1.day

    studio_one = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    studio_two = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix"
    })

    forecast_client = ForecastClient.create!

    past_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date - 2.days,
      end_date: start_date - 2.days
    })

    current_project_one = ForecastProject.create!({
      id: 2,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date,
      end_date: end_date
    })

    current_project_two = ForecastProject.create!({
      id: 3,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: start_date,
      end_date: end_date
    })

    future_project = ForecastProject.create!({
      id: 4,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: end_date + 2.days,
      end_date: end_date + 2.days
    })

    user_one = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user_two = AdminUser.create!({
      email: "gandalf@sanctuary.computer",
      password: "password"
    })

    person_one = ForecastPerson.create!({
      forecast_id: 123,
      roles: [studio_one.name],
      email: user_one.email
    })

    person_two = ForecastPerson.create!({
      forecast_id: 456,
      roles: [studio_two.name],
      email: user_two.email
    })

    FullTimePeriod.create!({
      admin_user: user_one,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    FullTimePeriod.create!({
      admin_user: user_two,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    [
      past_project,
      current_project_one,
      current_project_two,
      future_project
    ].each_with_index do |project, index|
      ForecastAssignment.create!({
        forecast_id: (index * 2) + 1,
        start_date: project.start_date,
        end_date: project.end_date,
        forecast_person: person_one,
        forecast_project: project,
        allocation: 4 * 60 * 60
      })

      ForecastAssignment.create!({
        forecast_id: (index * 2) + 2,
        start_date: project.start_date,
        end_date: project.end_date,
        forecast_person: person_two,
        forecast_project: project,
        allocation: 4 * 60 * 60
      })
    end

    snapshotter = Stacks::DailyFinancialSnapshotter.new
    snapshotter.snapshot!

    assert_snapshot_attributes([
      {
        forecast_person_id: person_one.id,
        forecast_project_id: current_project_one.id,
        effective_date: Date.today,
        studio_id: studio_one.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_two.id,
        forecast_project_id: current_project_one.id,
        effective_date: Date.today,
        studio_id: studio_two.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_one.id,
        forecast_project_id: current_project_two.id,
        effective_date: Date.today,
        studio_id: studio_one.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_two.id,
        forecast_project_id: current_project_two.id,
        effective_date: Date.today,
        studio_id: studio_two.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      }
    ])
  end

  test "#snapshot_all! creates snapshot records for all historical projects" do
    ForecastAssignment.delete_all

    today = Date.today

    studio_one = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    studio_two = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix"
    })

    forecast_client = ForecastClient.create!

    past_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: today - 2.days,
      end_date: today - 2.days
    })

    current_project_one = ForecastProject.create!({
      id: 2,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: today,
      end_date: today
    })

    current_project_two = ForecastProject.create!({
      id: 3,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: today,
      end_date: today
    })

    future_project = ForecastProject.create!({
      id: 4,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: today + 2.days,
      end_date: today + 2.days
    })

    user_one = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    user_two = AdminUser.create!({
      email: "gandalf@sanctuary.computer",
      password: "password"
    })

    person_one = ForecastPerson.create!({
      forecast_id: 123,
      roles: [studio_one.name],
      email: user_one.email
    })

    person_two = ForecastPerson.create!({
      forecast_id: 456,
      roles: [studio_two.name],
      email: user_two.email
    })

    FullTimePeriod.create!({
      admin_user: user_one,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    FullTimePeriod.create!({
      admin_user: user_two,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    [
      past_project,
      current_project_one,
      current_project_two,
      future_project
    ].each_with_index do |project, index|
      ForecastAssignment.create!({
        forecast_id: (index * 2) + 1,
        start_date: project.start_date,
        end_date: project.end_date,
        forecast_person: person_one,
        forecast_project: project,
        allocation: 4 * 60 * 60
      })

      ForecastAssignment.create!({
        forecast_id: (index * 2) + 2,
        start_date: project.start_date,
        end_date: project.end_date,
        forecast_person: person_two,
        forecast_project: project,
        allocation: 4 * 60 * 60
      })
    end

    Stacks::DailyFinancialSnapshotter.snapshot_all!

    assert_snapshot_attributes([
      {
        forecast_person_id: person_one.id,
        forecast_project_id: past_project.id,
        effective_date: past_project.start_date,
        studio_id: studio_one.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_two.id,
        forecast_project_id: past_project.id,
        effective_date: past_project.start_date,
        studio_id: studio_two.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_one.id,
        forecast_project_id: current_project_one.id,
        effective_date: current_project_one.start_date,
        studio_id: studio_one.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_two.id,
        forecast_project_id: current_project_one.id,
        effective_date: current_project_one.start_date,
        studio_id: studio_two.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_one.id,
        forecast_project_id: current_project_two.id,
        effective_date: current_project_two.start_date,
        studio_id: studio_one.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      },
      {
        forecast_person_id: person_two.id,
        forecast_project_id: current_project_two.id,
        effective_date: current_project_two.start_date,
        studio_id: studio_two.id,
        hourly_cost: 56.49,
        hours: 4,
        needs_review: false
      }
    ])
  end

  private

  def assert_snapshot_attributes(expected_attributes)
    fields = [
      :forecast_person_id,
      :forecast_project_id,
      :effective_date,
      :studio_id,
      :hourly_cost,
      :hours,
      :needs_review
    ]

    actual_attributes = ForecastAssignmentDailyFinancialSnapshot
      .pluck(*fields)
      .map { |row| fields.zip(row).to_h }

    assert_equal(expected_attributes, actual_attributes)
  end
end
