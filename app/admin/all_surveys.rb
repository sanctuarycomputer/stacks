ActiveAdmin.register_page "All Surveys" do
  menu label: -> {
    pending_count = current_admin_user.pending_survey_count

    if pending_count > 0
      div("#{pending_count}", class: "notifier")
    end

    "Surveys"
  },
  priority: 5

  content title: "Surveys" do
    div class: "blank_slate_container", id: "dashboard_default_message" do
      span class: "blank_slate" do
        span "Welcome to the Surveys Dashboard"
        small "Please select a specific survey type from the menu."
      end
    end
  end

  controller do
    def index
      # First, check for regular surveys needing a response
      pending_regular_survey = Survey.open.find do |s|
        s.expected_responders.include?(current_admin_user) &&
        SurveyResponder.find_by(survey: s, admin_user: current_admin_user).nil?
      end

      if pending_regular_survey.present?
        return redirect_to admin_surveys_path
      end

      # Next, check for project satisfaction surveys needing response
      pending_project_survey = ProjectSatisfactionSurvey.open.find do |pss|
        pss.expected_responders.keys.include?(current_admin_user) &&
        ProjectSatisfactionSurveyResponder.find_by(project_satisfaction_survey: pss, admin_user: current_admin_user).nil?
      end

      if pending_project_survey.present?
        return redirect_to admin_project_satisfaction_surveys_path
      end

      # Default to regular surveys if nothing is pending
      redirect_to admin_surveys_path
    end
  end
end