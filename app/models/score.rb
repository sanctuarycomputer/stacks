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

  def possible_bands
    if is_finalization_workspace?
      sorted_ints = score_tree.workspace.review.score_table[trait_id][:band].map { |s| Score.bands[s] }.sort
      spread = *(sorted_ints.min..sorted_ints.max)
      spread.map { |i| Score.bands.key(i) }
    else
      Score.bands.keys
    end
  end

  def possible_consistencies
    if (is_finalization_workspace? &&
        score_tree.workspace.review.score_table[trait_id][:band].uniq.length == 1)
      sorted_ints = score_tree.workspace.review.score_table[trait_id][:consistency].map { |s| Score.consistencies[s] }.sort
      spread = *(sorted_ints.min..sorted_ints.max)
      spread.map { |i| Score.consistencies.key(i) }
    else
      Score.consistencies.keys
    end
  end
end
