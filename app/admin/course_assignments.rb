# app/admin/course_assignments.rb
ActiveAdmin.register CourseAssignment do
  menu label: "Assignments", parent: "Onboarding", priority: 1, if: proc { current_admin_user.is_admin? }
  # No destroy: an admin waives instead, so delete-and-recreate can't reset a due date.
  actions :index, :show, :new, :create, :edit, :update
  permit_params :admin_user_id, :course_id, :due_on
  config.filters = false
  config.sort_order = "created_at_desc"
  includes :admin_user, :course

  before_create do |assignment|
    assignment.assigned_by = current_admin_user
    # An admin can't pick their own deadline: for themselves the course's
    # grace period applies (the model refills a blank due_on on create).
    assignment.due_on = nil if assignment.admin_user_id == current_admin_user.id
  end

  controller do
    helper_method :checklist, :checklist_for, :acting_as_assignee?, :acting_as_admin?

    # One Checklist per index row, however many columns read it.
    def checklist_for(assignment)
      (@checklists ||= {})[assignment.id] ||= Stacks::Learning::Checklist.new(assignment)
    end

    # The REST actions bypass the member-action guards below, so they get their own.
    include RefusesWritesWhileImpersonating
    before_action :refuse_own_due_date_change!, only: [:edit, :update]

    def checklist
      @checklist ||= Stacks::Learning::Checklist.new(resource)
    end

    # The signed-in person on their own checklist — never an admin impersonating them.
    def acting_as_assignee?
      !impersonating? && current_admin_user.id == resource.admin_user_id
    end

    # An admin acting on someone else's checklist, as themselves.
    def acting_as_admin?
      !impersonating? && current_admin_user.is_admin? && current_admin_user.id != resource.admin_user_id
    end

    # `resource` first, so ActiveAdmin's own authorization runs before ours.
    def refuse_own_due_date_change!
      return if resource.admin_user_id != current_admin_user.id
      redirect_to admin_course_assignments_path, alert: "You can't change your own due date."
    end

    # Records one step as done. A double click or a racing request finds the row
    # already there; that is not an error.
    def record_completion!(step, **attrs)
      StepCompletion.create!(admin_user: resource.admin_user, module_step: step, completed_at: Time.current, **attrs)
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      back(notice: "That was already done.")
      false
    end

    def back(flash_opts = {})
      redirect_to admin_course_assignment_path(resource), flash_opts
    end

    # The authorization adapter already allowed the action name; these guards
    # are the real enforcement of who may do what on which row.
    def require_assignee!
      return true if acting_as_assignee? && resource.outstanding?
      back(alert: impersonating? ? "Stop impersonating first." : "That isn't available on this checklist.")
      false
    end

    def require_admin!
      unless acting_as_admin?
        back(alert: impersonating? ? "Stop impersonating first." : "Only an admin can do that, and not on their own checklist.")
        return false
      end
      return true if resource.outstanding?
      back(alert: "This checklist is already closed.")
      false
    end

    # The person's write has already landed by the time we refresh; a failing
    # refresh must neither 500 their request nor hide that it was saved.
    def safe_refresh!(admin_user)
      Stacks::Learning::Progress.refresh!(admin_user)
    rescue StandardError => e
      Rails.logger.error("Learning progress refresh failed for AdminUser##{admin_user.id}: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end

    def step_state_from_params
      checklist.step_state(params[:step_id])
    end

    def module_state_from_params
      checklist.module_state(params[:learning_module_id])
    end

    # Only due_on is editable after creation.
    def update
      submitted = params[:course_assignment]
      due_on = submitted.respond_to?(:key?) ? submitted[:due_on] : nil
      params[:course_assignment] = ActionController::Parameters.new(due_on: due_on)
      super
    end
  end

  index download_links: false do
    column :person do |a|
      link_to a.admin_user.email, admin_course_assignment_path(a)
    end
    column :course
    column :assigned_on
    column :due_on
    column :state do |a|
      if a.completed? then status_tag("Done", class: "yes")
      elsif a.waived? then status_tag("Waived")
      elsif checklist_for(a).overdue? then status_tag("Overdue", class: "no")
      elsif a.due_on < Date.today then status_tag("Past due, not on them")
      else status_tag("In progress")
      end
    end
    column :steps do |a|
      "#{checklist_for(a).steps_done} of #{checklist_for(a).steps_total}"
    end
    actions defaults: false do |a|
      item "Edit due date", edit_admin_course_assignment_path(a)
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      if f.object.new_record?
        f.input :admin_user, as: :select, collection: AdminUser.order(:email).map { |u| [u.email, u.id] }
        f.input :course, as: :select, collection: Course.order(:name)
        f.input :due_on, as: :datepicker, hint: "Leave blank to use the course's grace period."
      else
        f.input :due_on, as: :datepicker
      end
    end
    f.actions
  end

  show title: proc { |a| a.course.learner_title } do
    render "show", assignment: resource, checklist: checklist
  end

  member_action :complete_step, method: :post do
    next unless require_assignee!
    state = step_state_from_params
    if state.nil? || state.done? || !%w[read do].include?(state.step.kind)
      next back(alert: "That step can't be marked done here.")
    end
    next unless record_completion!(state.step, source: "self")
    safe_refresh!(resource.admin_user)
    back(notice: "Done.")
  end

  member_action :quiz, method: :get do
    next head(:not_acceptable) unless request.format.html?
    @module_state = module_state_from_params
    if @module_state.nil? || !@module_state.has_quiz?
      next back(alert: "There is no quick check here.")
    end
    case @module_state.quiz_state
    when :passed
      # A ModuleCompletion alone is not a pass (questions may have been added after).
      next back(alert: "There's nothing to review here.") unless @module_state.passed? || acting_as_admin?
      @review = true
    when :open
      next back(alert: "Stop impersonating first.") if impersonating?
      next back(alert: "Only the person can take their quick check.") unless acting_as_assignee?
      next back(alert: "This checklist is closed.") unless resource.outstanding?
      @review = false
    else
      next back(alert: "The quick check isn't open.") unless acting_as_admin?
      @review = true
    end
    @page_title = "Quick check: #{@module_state.learning_module.name}"
    render "admin/course_assignments/quiz"
  end

  member_action :submit_quiz, method: :post do
    next unless require_assignee!
    learning_module = module_state_from_params&.learning_module
    next back(alert: "There is no quick check here.") if learning_module.nil?
    result = Stacks::Learning::Quiz.submit!(assignment: resource, learning_module: learning_module, answers: params[:answers],
                                         fingerprint: params[:fingerprint].to_s)
    back(result.status == :passed ? { notice: result.message } : { alert: result.message })
  end

  member_action :recheck, method: :post do
    next back(alert: "Stop impersonating first.") if impersonating?
    safe_refresh!(resource.admin_user)
    Stacks::TaskBuilder.clear_cache!
    back(notice: "Checked again.")
  end

  member_action :sign_off_step, method: :post do
    next unless require_admin!
    state = step_state_from_params
    next back(alert: "That step isn't ready to sign off.") if state.nil? || !state.ready
    next unless record_completion!(state.step, source: "admin", completed_by: current_admin_user)
    Stacks::Learning::Progress.allow_for_admin_delay!(resource)
    safe_refresh!(resource.admin_user)
    back(notice: "Signed off.")
  end

  member_action :complete_step_for, method: :post do
    next unless require_admin!
    state = step_state_from_params
    if state.nil? || state.done? || state.step.kind == "admin_sign_off"
      next back(alert: "That step can't be marked done here.")
    end
    next unless record_completion!(state.step, source: "admin", completed_by: current_admin_user)
    Stacks::Learning::Progress.allow_for_admin_delay!(resource)
    safe_refresh!(resource.admin_user)
    back(notice: "Marked done for #{resource.admin_user.email}.")
  end

  member_action :grant_quiz_retry, method: :post do
    next unless require_admin!
    state = module_state_from_params
    next back(alert: "They aren't out of attempts.") if state.nil? || state.quiz_state != :locked
    QuizRetryGrant.create!(admin_user: resource.admin_user, learning_module: state.learning_module,
                           granted_by: current_admin_user, note: params[:note].presence)
    back(notice: "Allowed one more attempt.")
  end

  member_action :waive, method: :post do
    next unless require_admin!
    resource.update!(waived_at: Time.current, waived_by: current_admin_user, waive_note: params[:waive_note].presence)
    back(notice: "Waived.")
  end
end
