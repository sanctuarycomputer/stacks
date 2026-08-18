require 'test_helper'

class StacksTaskBuilderDiscoveriesHumanOperatingManualsTest < ActiveSupport::TestCase
  def setup
    # No full-time period → inactive → excluded from the checked population,
    # so the fallback itself never generates tasks in these tests.
    @fallback = AdminUser.create!(email: "fallback@sanctuary.computer", password: "passw0rd")
  end

  def manual_page(props)
    NotionPage.new(data: { "properties" => props })
  end

  def email_prop(value)
    { "type" => "email", "email" => value }
  end

  def who_prop(value)
    { "type" => "people", "people" => [{ "person" => { "email" => value } }] }
  end

  def files_prop(files)
    { "type" => "files", "files" => files }
  end

  def discover(pages)
    NotionPage.stubs(:human_operating_manual).returns(pages)
    Stacks::TaskBuilder::Discoveries::HumanOperatingManuals.new(admin_fallback: [@fallback]).tasks
  end

  test "an active admin with no matching manual gets a missing_human_operating_manual task they own" do
    admin = build_admin!
    tasks = discover([manual_page("Email" => email_prop("someone.else@sanctuary.computer"))])

    task = tasks.find { |t| t.type == :missing_human_operating_manual }
    assert task, "expected a missing_human_operating_manual task"
    assert_equal admin, task.subject
    assert_equal [admin], task.owners
  end

  test "an active admin whose manual lacks a PDF gets a missing_superpowers_pdf task subjecting the manual" do
    admin = build_admin!
    page = manual_page("Email" => email_prop(admin.email))
    tasks = discover([page])

    task = tasks.find { |t| t.type == :missing_superpowers_pdf }
    assert task, "expected a missing_superpowers_pdf task"
    assert_kind_of Stacks::Notion::HumanOperatingManual, task.subject
    assert_equal page, task.subject.notion_page
    assert_equal [admin], task.owners
    refute tasks.any? { |t| t.type == :missing_human_operating_manual && t.subject == admin }
  end

  test "an active admin whose manual has a PDF gets no tasks" do
    admin = build_admin!
    tasks = discover([manual_page(
      "Email" => email_prop(admin.email),
      "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
    )])

    assert_empty tasks
  end

  test "email matching is case-insensitive" do
    admin = build_admin!
    tasks = discover([manual_page(
      "Email" => email_prop(admin.email.upcase),
      "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
    )])

    assert_empty tasks
  end

  test "manuals with no resolvable email (blank Email and empty Who) are ignored" do
    admin = build_admin!
    tasks = discover([manual_page("Email" => email_prop(nil))])

    task = tasks.find { |t| t.type == :missing_human_operating_manual }
    assert task
    assert_equal admin, task.subject
  end

  test "active admin with a Who-only manual (blank Email) and PDF gets no tasks" do
    admin = build_admin!
    tasks = discover([manual_page(
      "Who" => who_prop(admin.email.upcase),
      "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
    )])

    assert_empty tasks
  end

  test "active admin with a Who-only manual (blank Email) but no PDF gets missing_superpowers_pdf" do
    admin = build_admin!
    tasks = discover([manual_page("Who" => who_prop(admin.email.upcase))])

    task = tasks.find { |t| t.type == :missing_superpowers_pdf }
    assert task, "expected a missing_superpowers_pdf task"
    assert_equal [admin], task.owners
    refute tasks.any? { |t| t.type == :missing_human_operating_manual && t.subject == admin }
  end

  test "ignored admins are skipped" do
    admin = build_admin!
    admin.update!(ignore: true)
    assert_empty discover([manual_page("Email" => email_prop("someone.else@sanctuary.computer"))])
  end

  test "inactive admins are skipped" do
    build_admin!(ended_at: Date.today - 1)
    assert_empty discover([manual_page("Email" => email_prop("someone.else@sanctuary.computer"))])
  end

  test "when the manual database has never been synced, no tasks are emitted" do
    build_admin!
    assert_empty discover([])
  end

  test "with multiple matching manuals, a PDF on any of them satisfies the check" do
    admin = build_admin!
    tasks = discover([
      manual_page("Email" => email_prop(admin.email)),
      manual_page(
        "Email" => email_prop(admin.email),
        "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
      )
    ])

    assert_empty tasks
  end

  test "both task types have explicit humanized labels" do
    assert_equal "Admin user needs a Human Operating Manual",
      StacksTask::HUMANIZED_TYPES[:missing_human_operating_manual]
    assert_equal "Human Operating Manual needs a Pigment.is Superpowers PDF",
      StacksTask::HUMANIZED_TYPES[:missing_superpowers_pdf]
  end

  test "a missing_superpowers_pdf task links externally to the assessment guide" do
    admin = build_admin!
    page = manual_page("Email" => email_prop(admin.email))
    tasks = discover([page])

    task = tasks.find { |t| t.type == :missing_superpowers_pdf }
    assert_equal "human_operating_manuals", task.subject_class_key
    assert_equal Stacks::Notion::HumanOperatingManual::ASSESSMENT_GUIDE_URL, task.subject_url
    assert task.subject_url_external?
  end

  test "a missing_human_operating_manual task links externally to the setup guide" do
    admin = build_admin!
    tasks = discover([manual_page("Email" => email_prop("someone.else@sanctuary.computer"))])

    task = tasks.find { |t| t.type == :missing_human_operating_manual }
    assert_equal Stacks::Notion::HumanOperatingManual::SETUP_GUIDE_URL, task.subject_url
    assert task.subject_url_external?
  end

  test "a missing_superpowers_pdf task displays the manual's title, falling back to email" do
    admin = build_admin!
    titled = manual_page("Email" => email_prop(admin.email))
    titled.page_title = "Hugh's Manual"
    tasks = discover([titled])
    assert_equal "Hugh's Manual", tasks.find { |t| t.type == :missing_superpowers_pdf }.subject_display_name

    untitled = manual_page("Email" => email_prop(admin.email))
    tasks = discover([untitled])
    assert_equal admin.email.downcase, tasks.find { |t| t.type == :missing_superpowers_pdf }.subject_display_name
  end
end
