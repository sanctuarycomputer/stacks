class Stacks::Zenhub
  require 'graphql/client'
  require 'graphql/client/http'

  # TODO
  # - story points per billable hour OKR

  HTTP = GraphQL::Client::HTTP.new('https://api.zenhub.com/public/graphql') do
    def headers(context)
      {
        "Authorization" => "Bearer #{Stacks::Utils.config[:zenhub][:access_token]}"
      }
    end
  end

  Schema = GraphQL::Client.load_schema(HTTP)
  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

  ZenhubOrgsAndWorkspacesQuery = Client.parse <<-'GRAPHQL'
    query($workspace_end_cursor: String) {
      viewer {
        zenhubOrganizations {
          nodes {
            id
            name
            workspaces(first: 100, after: $workspace_end_cursor) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id
                name
                createdAt
                updatedAt
              }
            }
          }
        }
      }
    }
  GRAPHQL

  ZenhubWorkspaceRepositoryConnectionsQuery = Client.parse <<-'GRAPHQL'
    query($workspace_id: ID!, $repositories_connection_end_cursor: String) {
      workspace(id: $workspace_id) {
        repositoriesConnection(first: 100,after: $repositories_connection_end_cursor) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            ghId
          }
        }
      }
    }
  GRAPHQL

  ZenhubWorkspaceIssuesQuery = Client.parse <<-'GRAPHQL'
    query($workspace_id: ID!, $issues_end_cursor: String) {
      workspace(id: $workspace_id) {
        issues(first: 100, after: $issues_end_cursor) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            ghId
            ghNodeId
            repository {
              ghId
            }
            type
            state
            pullRequest
            createdAt
            updatedAt
            title
            number
            closedAt
            user {
              ghId
            }
            assignees {
              nodes {
                ghId
              }
            }
            estimate {
              value
            }
            connectedPrs {
              nodes {
                id
              }
            }
          }
        }
      }
    }
  GRAPHQL

  ZenhubWorkspaceClosedIssuesQuery = Client.parse <<-'GRAPHQL'
    query($workspace_id: ID!, $zenhub_repository_ids: [ID!], $issues_end_cursor: String) {
      searchClosedIssues(
        first: 100,
        after: $issues_end_cursor,
        workspaceId: $workspace_id,
        filters: {
          repositoryIds: $zenhub_repository_ids
        }
      ) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          ghId
          ghNodeId
          repository {
            ghId
          }
          type
          state
          pullRequest
          createdAt
          updatedAt
          title
          closedAt
          number
          user {
            ghId
          }
          assignees {
            nodes {
              ghId
            }
          }
          estimate {
            value
          }
          connectedPrs {
            nodes {
              id
            }
          }
        }
      }

    }
  GRAPHQL

  def self.sync_all!
    ActiveRecord::Base.transaction do
      ZenhubWorkspace.delete_all
      ZenhubWorkspaceGithubRepositoryConnection.delete_all
      ZenhubIssue.delete_all
      ZenhubIssueConnectedPullRequest.delete_all
      ZenhubIssueAssignee.delete_all

      sync_workspaces
      sync_github_repositories_for_workspaces
      sync_zenhub_issues_for_workspaces
    end
  end

  def self.sync_workspaces
    end_cursor = nil
    loop do
      result = Client.query(ZenhubOrgsAndWorkspacesQuery, variables: { workspacesEndCursor: end_cursor })
      sanctuary = result.data.viewer.zenhub_organizations.nodes.find{|n| n.name  == "sanctuarycomputer" }
      data = sanctuary.workspaces.nodes.map do |workspace|
        {
          zenhub_id: workspace.id,
          name: workspace.name,
          created_at: workspace.created_at,
          updated_at: workspace.updated_at,
        }
      end
      ZenhubWorkspace.upsert_all(data, unique_by: :zenhub_id) if data.any?
      break unless sanctuary.workspaces.page_info.has_next_page
      end_cursor = sanctuary.workspaces.page_info.end_cursor
    end
  end

  def self.sync_github_repositories_for_workspaces
    ZenhubWorkspace.all.each do |workspace|
      end_cursor = nil
      loop do
        result = Client.query(
          ZenhubWorkspaceRepositoryConnectionsQuery,
          variables: {
            workspace_id: workspace.zenhub_id,
            repositories_connection_end_cursor: end_cursor
          }
        )
        data = result.data.workspace.repositories_connection.nodes.map do |n|
          {
            zenhub_id: n.id,
            zenhub_workspace_id: workspace.zenhub_id,
            github_repo_id: n.gh_id,
          }
        end
        ZenhubWorkspaceGithubRepositoryConnection.upsert_all(
          data,
          unique_by: [:zenhub_id],
        ) if data.any?
        break unless result.data.workspace.repositories_connection.page_info.has_next_page
        end_cursor = result.data.workspace.repositories_connection.page_info.end_cursor
      end
    end
  end

  def self.sync_zenhub_issues_for_workspaces
    ZenhubWorkspace.includes(:zenhub_workspace_github_repository_connections).all.each do |workspace|
      end_cursor = nil

      # ZenhubWorkspaceIssuesQuery
      loop do
        result = Client.query(
          ZenhubWorkspaceIssuesQuery,
          variables: {
            workspace_id: workspace.zenhub_id,
            issues_end_cursor: end_cursor
          }
        )
        connected_pull_request_issue_data = []
        assignee_data = []
        data = result.data.workspace.issues.nodes.map do |n|
          n.connected_prs.nodes.each do |pr|
            connected_pull_request_issue_data << {
              zenhub_issue_id: n.id,
              zenhub_pull_request_issue_id: pr.id
            }
          end
          n.assignees.nodes.each do |assignee|
            assignee_data << {
              zenhub_issue_id: n.id,
              github_user_id: assignee.gh_id
            }
          end
          {
            zenhub_id: n.id,
            zenhub_workspace_id: workspace.zenhub_id,
            github_repo_id: n.repository.gh_id,
            github_user_id: n.user.gh_id,
            issue_type: n.type,
            issue_state: n.state,
            estimate: n.estimate&.value,
            number: n.number,
            github_issue_id: n.gh_id,
            github_issue_node_id: n.gh_node_id,
            title: n.title,
            is_pull_request: n.pull_request,
            created_at: n.created_at,
            updated_at: n.updated_at,
            closed_at: n.closed_at,
          }
        end
        ZenhubIssue.upsert_all(
          data,
          unique_by: [:zenhub_id],
        ) if data.any?
        ZenhubIssueConnectedPullRequest.upsert_all(
          connected_pull_request_issue_data,
          unique_by: [:zenhub_issue_id, :zenhub_pull_request_issue_id],
        ) if connected_pull_request_issue_data.any?
        ZenhubIssueAssignee.upsert_all(
          assignee_data,
          unique_by: [:zenhub_issue_id, :github_user_id],
        ) if assignee_data.any?
        puts "Synced #{data.count} issues for workspace #{workspace.name}"
        break unless result.data.workspace.issues.page_info.has_next_page
        end_cursor = result.data.workspace.issues.page_info.end_cursor
      end

      # ZenhubWorkspaceClosedIssuesQuery
      loop do
        result = Client.query(
          ZenhubWorkspaceClosedIssuesQuery,
          variables: {
            workspace_id: workspace.zenhub_id,
            zenhub_repository_ids: workspace.zenhub_workspace_github_repository_connections.pluck(:zenhub_id),
            issues_end_cursor: end_cursor
          }
        )
        connected_pull_request_issue_data = []
        assignee_data = []
        data = result.data.search_closed_issues.nodes.map do |n|
          n.connected_prs.nodes.each do |pr|
            connected_pull_request_issue_data << {
              zenhub_issue_id: n.id,
              zenhub_pull_request_issue_id: pr.id
            }
          end
          n.assignees.nodes.each do |assignee|
            assignee_data << {
              zenhub_issue_id: n.id,
              github_user_id: assignee.gh_id
            }
          end
          {
            zenhub_id: n.id,
            zenhub_workspace_id: workspace.zenhub_id,
            github_repo_id: n.repository.gh_id,
            github_user_id: n.user.gh_id,
            issue_type: n.type,
            issue_state: n.state,
            estimate: n.estimate&.value,
            number: n.number,
            github_issue_id: n.gh_id,
            github_issue_node_id: n.gh_node_id,
            title: n.title,
            is_pull_request: n.pull_request,
            created_at: n.created_at,
            updated_at: n.updated_at,
            closed_at: n.closed_at,
          }
        end
        ZenhubIssue.upsert_all(
          data,
          unique_by: [:zenhub_id],
        ) if data.any?
        ZenhubIssueConnectedPullRequest.upsert_all(
          connected_pull_request_issue_data,
          unique_by: [:zenhub_issue_id, :zenhub_pull_request_issue_id],
        ) if connected_pull_request_issue_data.any?
        ZenhubIssueAssignee.upsert_all(
          assignee_data,
          unique_by: [:zenhub_issue_id, :github_user_id],
        ) if assignee_data.any?
        puts "Synced #{data.count} CLOSED issues for workspace #{workspace.name}"
        break unless result.data.search_closed_issues.page_info.has_next_page
        end_cursor = result.data.search_closed_issues.page_info.end_cursor
      end

    end
  end
end
