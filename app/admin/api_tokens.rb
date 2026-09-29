# API tokens: scoped, revocable credentials for the Stacks API and MCP surfaces (see ApiToken). Admins only
# (AdminAuthorization). A token's plaintext is shown exactly once, on the page right after it is minted.
ActiveAdmin.register ApiToken do
  menu if: -> { current_admin_user.is_admin? }, parent: "Dashboard", label: "API Tokens"
  config.filters = false
  config.sort_order = "created_at_desc"
  actions :index, :show, :new, :create

  permit_params :name, :expires_at, scopes: []

  index download_links: false do
    column :name
    column("Token") { |t| "#{t.token_prefix}…" }
    column(:scopes) { |t| t.scopes.join(", ") }
    column(:created_by) { |t| t.created_by&.email }
    column :last_used_at
    column :expires_at
    column("Status") { |t| t.revoked_at ? "revoked #{t.revoked_at.to_date}" : (t.active? ? "active" : "expired") }
    actions defaults: false do |t|
      item("View", admin_api_token_path(t))
      unless t.revoked_at
        text_node " "
        item("Revoke", revoke_admin_api_token_path(t), method: :post, data: { confirm: "Revoke #{t.name}? It stops working immediately." })
      end
    end
  end

  show do
    if (raw = controller.instance_variable_get(:@minted_token))
      panel "Copy this token now: it won't be shown again" do
        pre raw
      end
    end
    attributes_table do
      row :name
      row("Token") { |t| "#{t.token_prefix}…" }
      row(:scopes) { |t| t.scopes.map { |s| "#{s}: #{ApiToken::SCOPES[s]}" }.join("; ") }
      row(:created_by) { |t| t.created_by&.email }
      row :created_at
      row :last_used_at
      row :expires_at
      row :revoked_at
    end
  end

  form do |f|
    f.inputs "Mint a token" do
      f.input :name, hint: "Who or what uses it, e.g. \"Stacksbot write\""
      f.input :scopes, as: :check_boxes, collection: ApiToken::SCOPES.map { |k, v| ["#{k}: #{v}", k] }, hint: "Least privilege: only what this caller needs."
      f.input :expires_at, as: :datepicker, hint: "Optional"
    end
    f.actions
  end

  member_action :revoke, method: :post do
    resource.revoke!
    redirect_to admin_api_tokens_path, notice: "#{resource.name} is revoked; it stopped working immediately."
  end

  controller do
    def create
      # A hand-written create skips ActiveAdmin's build_resource, which is where it authorizes: check explicitly.
      authorize! ActiveAdmin::Auth::CREATE, ApiToken
      record, raw = ApiToken.mint!(
        name: params.dig(:api_token, :name),
        scopes: Array(params.dig(:api_token, :scopes)),
        expires_at: params.dig(:api_token, :expires_at).presence,
        created_by: current_admin_user,
      )
      # Render (don't redirect): the plaintext lives only in this one response, never in a cookie or the log.
      @resource = record
      @minted_token = raw
      response.headers["Cache-Control"] = "no-store"
      render :show
    rescue ActiveRecord::RecordInvalid => e
      @resource = e.record
      flash.now[:error] = e.record.errors.full_messages.to_sentence
      render :new
    end
  end
end
