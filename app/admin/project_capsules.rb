ActiveAdmin.register ProjectCapsule do
  menu false
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :edit, :update

  permit_params :client_feedback_survey_status,
    :client_feedback_survey_url,
    :internal_marketing_status,
    :capsule_status,
    :postpartum_notes,
    :client_satisfaction_status,
    :client_satisfaction_detail,
    :project_satisfaction_survey_status

  controller do
    def update
      super do |success,failure|
        success.html {
          redirect_to admin_project_tracker_path(resource.project_tracker_id)
        }
      end
    end
  end

  action_item :create_project_satisfaction_survey, only: [:edit] do
    if resource.project_satisfaction_survey.nil?
      link_to "Create Project Satisfaction Survey", create_project_satisfaction_survey_admin_project_capsule_path(resource), method: :post
    else
      link_to "View Project Satisfaction Survey", admin_project_satisfaction_survey_path(resource.project_satisfaction_survey)
    end
  end

  member_action :create_project_satisfaction_survey, method: :post do
    redirect_to new_admin_project_satisfaction_survey_path(project_capsule_id: resource.id), notice: "Please confirm the survey questions before creating the survey."
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :client_feedback_survey_status
      f.input :client_feedback_survey_url,
        placeholder: "https://www.notion.so/garden3d/Interchain-26a131fea2c78182ac21f2aa1434a6b7",
        label: "Client Happiness Survey Response".html_safe,
        hint: <<~HTML.html_safe
        <div class="dashboard-module" style="pointer-events: auto; margin: 20px 0px;">
          <div class="module-header" style="pointer-events: auto;">
            <p>💬 Client Feedback Survey</p>
            <p><a href='https://www.notion.so/garden3d/Survey-a-client-on-their-experience-working-with-us-b76b31a861a14f09a33cf453563e6191' target='_blank'>Instructions ↗</a></p>
          </div>
          <div class="module-body">
            <p style="margin-bottom: 6px;">Email your client a link to our <a href='https://garden3d.notion.site/237131fea2c78032914ff97854ef2e6d' target='_blank'>Client Happiness Survey</a>.</p>
            <p>Be persistent! You may need to send multiple reminders. Once they've responded, paste the Notion URL to their response above, and select <strong>"Client Feedback Survey Received & Shared with Project Team"</strong>.</p>
          </div>
        </div>
        HTML


      f.input :client_satisfaction_status,
        label: "Client Happiness".html_safe,
        hint: <<~HTML.html_safe
        <div class="dashboard-module" style="pointer-events: auto; margin: 20px 0px;">
          <div class="module-header" style="pointer-events: auto;">
            <p>🙂 Client Happiness</p>
            <p><a href='https://www.notion.so/garden3d/What-a-successful-project-is-d430681549fc40e2af5ec4b7452fd94a' target='_blank'>Instructions ↗</a></p>
          </div>
          <div class="module-body">
            <ul>
              <li><p>The client asked for new/future work following the original engagement</p></li>
              <li><p>The client rated their satisfaction as 3+ (out of 5) in their client feedback survey</p></li>
              <li><p>The client has confirmed they'd recommend us to their friends</p></li>
              <li><p>The client gave us a testimonial or has offered to serve as a reference for us</p></li>
              <li><p>The client did not raise serious doubts in our ability to execute, escalate a concern, or threaten to fire us</p></li>
            </ul>
          </div>
        </div>
        HTML

      f.input :internal_marketing_status,
        hint: <<~HTML.html_safe
        <div class="dashboard-module" style="pointer-events: auto; margin: 20px 0px;">
          <div class="module-header" style="pointer-events: auto;">
            <p>✍️ Case Study Production</p>
          </div>
          <div class="module-body">
            <p style="margin-bottom: 6px;">Generally, we'll want to produce a case study for most projects. At this stage, you'll just need to discuss that with our communications team, and they'll take it from here.</p>
            <a href='https://www.notion.so/garden3d/Creating-a-Project-Capsule-Profitability-Study-c5a17dbb8be74edc8960a61b2484aa0e?source=copy_link#2a7131fea2c780ee890af1454a1579a6' target='_blank'>How to schedule a case study ↗</a>
          </div>
        </div>
        HTML


      f.input :capsule_status,
        hint: <<~HTML.html_safe
        <div class="dashboard-module" style="pointer-events: auto; margin: 20px 0px;">
          <div class="module-header" style="pointer-events: auto;">
            <p>✍️ Internal Sharing of Project Capsule</p>
          </div>
          <div class="module-body">
            <p style="margin-bottom: 6px;">For team morale & growth, we encourage all Team Leads to share all project capsules with the entire garden3d team on Twist. Here's a few capsule threads in Twist for inspiration:</p>
            <ul>
              <li><p><a href='https://twist.com/a/133876/ch/355509/t/6877281/' target='_blank'>Williamstown Theatre Festival ↗</a></p></li>
              <li><p><a href='https://twist.com/a/133876/ch/355509/t/6844523/' target='_blank'>SOS Kicks User Testing ↗</a></p></li>
              <li><p><a href='https://twist.com/a/133876/ch/355509/t/6749098/' target='_blank'>Loupe This iOS ↗</a></p></li>
              <li><p><a href='https://twist.com/a/133876/ch/355509/t/6620923/' target='_blank'>Brooklyn Museum ↗</a></p></li>
              <li><p><a href='https://twist.com/a/133876/ch/355509/t/6695478/' target='_blank'>Magic Leap ↗</a></p></li>
            </ul>
          </div>
        </div>
        HTML

      f.input :project_satisfaction_survey_status,
        hint: <<~HTML.html_safe
        <div class="dashboard-module" style="pointer-events: auto; margin: 20px 0px;">
          <div class="module-header" style="pointer-events: auto;">
            <p>✍️ Internal Project Team Satisfaction Survey</p>
          </div>
          <div class="module-body">
            <p style="margin-bottom: 6px;">This Project Satisfaction Survey is for internal use only; only the team members on the project are responsible for completing it.</p>
            <a href='https://www.notion.so/garden3d/Creating-a-Project-Capsule-Profitability-Study-c5a17dbb8be74edc8960a61b2484aa0e?source=copy_link#2a4131fea2c78098b230f40a0aff301f' target='_blank'>How to setup an Internal Project Team Satisfaction Survey ↗</a>
          </div>
        </div>
        HTML
    end

    f.actions
  end
end
