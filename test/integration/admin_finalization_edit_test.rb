require 'test_helper'

# A reviewee with no archived review of their own gets blank (nil) scores in
# every workspace — ScoreTree#build_scores only pre-fills from a prior
# finalization. So until every peer has scored, the finalization screen has to
# cope with nil bands/consistencies: the comparitor table used to call
# `nil.titleize`, and Score#possible_bands used to sort a list containing nil.
# (sanctuarycomputer/stacks#24)
class AdminFinalizationEditTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = make_user!("finadmin", roles: ['admin'])
    sign_in @admin

    @tree = Tree.create!(name: "Engineer")
    @trait_a = Trait.create!(tree: @tree, name: "Trait A #{SecureRandom.hex(2)}")
    @trait_b = Trait.create!(tree: @tree, name: "Trait B #{SecureRandom.hex(2)}")

    @reviewee = make_user!("reviewee")
    @peer = make_user!("peer")

    align_workspace_and_score_tree_ids!
    @review = Review.new(admin_user: @reviewee)
    @review.review_trees.build(tree: @tree)
    @review.peer_reviews.build(admin_user: @peer)
    @review.save!
  end

  def make_user!(prefix, roles: [])
    AdminUser.create!(
      email: "#{prefix}#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: roles
    )
  end

  # Workspace#score_trees' scope calls `where(workspace: self)` inside a
  # zero-arity lambda, where `self` is the ScoreTree relation, so it also
  # filters on `workspace_id IN (SELECT id FROM score_trees)`. On a populated
  # database that is always true; on a fresh test database it depends on how
  # far the two id sequences have drifted. Start them level so every workspace
  # created below has a score tree with a matching id.
  def align_workspace_and_score_tree_ids!
    ActiveRecord::Base.connection.execute(<<~SQL)
      SELECT setval('workspaces_id_seq', n, false), setval('score_trees_id_seq', n, false)
      FROM (
        SELECT GREATEST(
          (SELECT COALESCE(MAX(id), 0) FROM workspaces),
          (SELECT COALESCE(MAX(id), 0) FROM score_trees)
        ) + 1 AS n
      ) next_id
    SQL
  end

  def score!(workspace, band:, consistency:)
    workspace.reload.all_scores.each do |s|
      s.update!(band: band, consistency: consistency)
    end
  end

  # The read-only band/consistency cells of each reviewer's comparitor table.
  def input_values
    response.body.split('<div id="comparitor_table">').drop(1).flat_map do |table|
      table.scan(/<input readonly="readonly" type="text" value="([^"]*)">/).flatten
    end
  end

  test "the reviewee has no prior review, so their scores start blank" do
    assert_empty @reviewee.archived_reviews
    assert @review.workspace.all_scores.all? { |s| s.band.nil? && s.consistency.nil? }
  end

  test "the finalization screen renders while a peer has not scored yet" do
    score!(@review.workspace, band: :senior, consistency: :meets_expectations)

    get edit_admin_finalization_path(@review.finalization)

    assert_response :success
    # Two traits for the reviewee, two blank cells for the pending peer.
    assert_equal ["Senior", "Meets expectations"] * 2 + [""] * 4, input_values
  end

  test "the finalization screen renders before anyone has scored" do
    get edit_admin_finalization_path(@review.finalization)

    assert_response :success
    assert_equal [""] * 8, input_values
  end

  test "the finalization screen still renders once everyone has scored" do
    score!(@review.workspace, band: :senior, consistency: :meets_expectations)
    score!(@review.peer_reviews.first.workspace, band: :lead, consistency: :exceptional)

    get edit_admin_finalization_path(@review.finalization)

    assert_response :success
    assert_equal ["Senior", "Meets expectations"] * 2 + ["Lead", "Exceptional"] * 2, input_values
  end

  test "possible bands and consistencies stay open until every reviewer has scored" do
    score!(@review.workspace, band: :mid_level, consistency: :still_learning)

    finalization_score = @review.finalization.workspace.reload.all_scores.first
    assert_equal Score.bands.keys, finalization_score.possible_bands
    assert_equal Score.consistencies.keys, finalization_score.possible_consistencies
  end

  test "possible bands and consistencies span the scores once everyone has scored" do
    score!(@review.workspace, band: :mid_level, consistency: :still_learning)
    score!(@review.peer_reviews.first.workspace, band: :senior, consistency: :still_learning)

    finalization_score = @review.finalization.workspace.reload.all_scores.first
    assert_equal ["mid_level", "experienced_mid_level", "senior"], finalization_score.possible_bands
    assert_equal Score.consistencies.keys, finalization_score.possible_consistencies

    score!(@review.peer_reviews.first.workspace, band: :mid_level, consistency: :meets_expectations)
    finalization_score.reload
    assert_equal ["mid_level"], finalization_score.possible_bands
    assert_equal ["still_learning", "mostly_meets_expectations", "meets_expectations"], finalization_score.possible_consistencies
  end

  test "possible bands and consistencies fall back to every option when nobody has scored" do
    finalization_score = @review.finalization.workspace.all_scores.first

    assert_equal Score.bands.keys, finalization_score.possible_bands
    assert_equal Score.consistencies.keys, finalization_score.possible_consistencies
  end
end
