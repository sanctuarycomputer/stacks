class AddScoreToProjectSatisfactionSurveys < ActiveRecord::Migration[6.1]
  def up
    add_column :project_satisfaction_surveys, :score, :decimal, precision: 5, scale: 2

    say_with_time "Backfill project_satisfaction_surveys.score for closed surveys" do
      ProjectSatisfactionSurvey.reset_column_information
      ProjectSatisfactionSurvey.where.not(closed_at: nil).find_each do |survey|
        rating = survey.overall_rating_from_question_responses
        survey.update_columns(score: rating, updated_at: Time.current)
      end
    end
  end

  def down
    remove_column :project_satisfaction_surveys, :score
  end
end
