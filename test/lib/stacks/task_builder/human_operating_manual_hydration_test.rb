require 'test_helper'

class StacksTaskBuilderHumanOperatingManualHydrationTest < ActiveSupport::TestCase
  test "descriptors for manual subjects round-trip through hydrate as re-wrapped manuals" do
    admin = build_admin!
    page = NotionPage.create!(
      notion_id: "11111111-2222-3333-4444-555555555555",
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:HUMAN_OPERATING_MANUALS]),
      page_title: "Test Manual",
      data: { "properties" => {} }
    )
    builder = Stacks::TaskBuilder.new
    manual = page.as_human_operating_manual
    task = StacksTask.new(type: :missing_superpowers_pdf, subject: manual, owners: [admin])

    descriptor = builder.send(:descriptor_for, task)
    assert_equal "Stacks::Notion::HumanOperatingManual", descriptor[:subject_type]
    assert_equal page.id, descriptor[:subject_id]

    hydrated = builder.send(:hydrate, [descriptor])
    assert_equal 1, hydrated.length
    assert_kind_of Stacks::Notion::HumanOperatingManual, hydrated.first.subject
    assert_equal page, hydrated.first.subject.notion_page
    assert_equal [admin], hydrated.first.owners
  end
end
