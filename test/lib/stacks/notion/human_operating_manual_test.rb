require 'test_helper'

class StacksNotionHumanOperatingManualTest < ActiveSupport::TestCase
  def manual_with_props(props)
    NotionPage.new(data: { "properties" => props }).as_human_operating_manual
  end

  def email_prop(value)
    { "type" => "email", "email" => value }
  end

  def files_prop(files)
    { "type" => "files", "files" => files }
  end

  def who_prop(value)
    { "type" => "people", "people" => [{ "person" => { "email" => value } }] }
  end

  # --- emails / email ---

  test "#emails returns the downcased Email property" do
    manual = manual_with_props("Email" => email_prop("Hugh@Sanctuary.computer"))
    assert_equal ["hugh@sanctuary.computer"], manual.emails
  end

  test "#emails returns Who person emails when Email is blank" do
    manual = manual_with_props("Who" => who_prop("Alice@sanctuary.computer"))
    assert_equal ["alice@sanctuary.computer"], manual.emails
  end

  test "#emails merges Email and Who, deduplicating when they match" do
    manual = manual_with_props(
      "Email" => email_prop("hugh@sanctuary.computer"),
      "Who"   => who_prop("Hugh@Sanctuary.computer")
    )
    assert_equal ["hugh@sanctuary.computer"], manual.emails
  end

  test "#emails merges Email and Who when they differ" do
    manual = manual_with_props(
      "Email" => email_prop("a@sanctuary.computer"),
      "Who"   => who_prop("B@sanctuary.computer")
    )
    assert_equal ["a@sanctuary.computer", "b@sanctuary.computer"], manual.emails
  end

  test "#emails returns [] when both Email and Who are absent" do
    assert_equal [], manual_with_props({}).emails
    assert_equal [], manual_with_props("Email" => email_prop(nil)).emails
  end

  test "#email returns the first resolvable email" do
    manual = manual_with_props("Email" => email_prop("Hugh@Sanctuary.computer"))
    assert_equal "hugh@sanctuary.computer", manual.email
  end

  test "#email returns nil when no resolvable email exists" do
    assert_nil manual_with_props({}).email
    assert_nil manual_with_props("Email" => email_prop(nil)).email
  end

  # --- superpowers_pdf? ---

  test "#superpowers_pdf? is true when the PDF property holds at least one file" do
    manual = manual_with_props(
      "Pigment.is Superpowers PDF" => files_prop([{ "name" => "superpowers.pdf" }])
    )
    assert manual.superpowers_pdf?
  end

  test "#superpowers_pdf? is false when the PDF property is empty or missing" do
    refute manual_with_props("Pigment.is Superpowers PDF" => files_prop([])).superpowers_pdf?
    refute manual_with_props({}).superpowers_pdf?
  end

  # --- .all ---

  test ".all wraps every page in the human_operating_manual scope" do
    page = NotionPage.new(data: { "properties" => {} })
    NotionPage.stubs(:human_operating_manual).returns([page])
    all = Stacks::Notion::HumanOperatingManual.all
    assert_equal 1, all.length
    assert_kind_of Stacks::Notion::HumanOperatingManual, all.first
  end
end
