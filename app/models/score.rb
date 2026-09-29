class Score < ApplicationRecord
  acts_as_paranoid

  belongs_to :trait
  belongs_to :score_tree
  enum band: {
    junior: 0,
    mid_level: 1,
    experienced_mid_level: 2,
    senior: 3,
    lead: 4,
  }
  enum consistency: {
    still_learning: 0,
    mostly_meets_expectations: 1,
    meets_expectations: 2,
    exceeds_expectations: 3,
    exceptional: 4,
  }

  def score_to_points
    begin
      ((Score.bands[band] * 10) + 10) + (Score.consistencies[consistency] * 2)
    rescue => e
      0
    end
  end

  def display_name
    self.trait.name
  end

  def is_finalization_workspace?
    score_tree.workspace.reviewable_type == "Finalization"
  end

  # Until every reviewer has scored this trait (e.g. a peer review is still
  # pending for someone with no prior review to pre-fill from), there is no
  # spread to narrow the choice to, so every option stays available.
  def possible_bands
    if is_finalization_workspace? && all_reviewers_scored?(:band)
      sorted_ints = score_tree.workspace.review.score_table[trait_id][:band].map { |s| Score.bands[s] }.sort
      spread = *(sorted_ints.min..sorted_ints.max)
      spread.map { |i| Score.bands.key(i) }
    else
      Score.bands.keys
    end
  end

  def possible_consistencies
    if (is_finalization_workspace? &&
        all_reviewers_scored?(:band) &&
        all_reviewers_scored?(:consistency) &&
        score_tree.workspace.review.score_table[trait_id][:band].uniq.length == 1)
      sorted_ints = score_tree.workspace.review.score_table[trait_id][:consistency].map { |s| Score.consistencies[s] }.sort
      spread = *(sorted_ints.min..sorted_ints.max)
      spread.map { |i| Score.consistencies.key(i) }
    else
      Score.consistencies.keys
    end
  end

  private

  def all_reviewers_scored?(attribute)
    scores = score_tree.workspace.review.score_table.dig(trait_id, attribute)
    scores.present? && scores.none?(&:nil?)
  end
end
