# test/lib/stacks/notion/markdown_test.rb
require 'test_helper'

class StacksNotionMarkdownTest < ActiveSupport::TestCase
  test "renders the fixture tree to the golden markdown" do
    tree = JSON.parse(file_fixture("notion/blocks_tree.json").read)
    golden = file_fixture("notion/blocks_tree.md").read
    assert_equal golden, Stacks::Notion::Markdown.render_blocks(tree, "p")
  end

  test "render reads from the mirror" do
    page = "3bf131fe-a2c7-8092-87f3-c668e91d5332"
    Stacks::Notion::Mirror.replace_level(parent_id: page, page_id: page, blocks: [
      { "id" => "x", "type" => "paragraph", "has_children" => false, "paragraph" => { "rich_text" => [{ "plain_text" => "hi", "annotations" => {}, "href" => nil }] } }
    ], fetched_at: Time.current)
    assert_equal "hi\n", Stacks::Notion::Markdown.render(page)
  end
end
