class Stacks::Github
  require 'octokit'

  def initialize(access_token = Stacks::Utils.config[:github][:access_token])
    @client = Octokit::Client.new(access_token: access_token)
  end

  def self.sync_all!
    ActiveRecord::Base.transaction do
      new.sync_repos
      new.sync_pull_requests
      new.sync_issues
    end
  end

  def sync_repos
    data = []
    page = 1

    loop do
      current_page_repos = @client.org_repos('sanctuarycomputer', type: 'all', page: page, per_page: 100)
      puts "Fetched #{current_page_repos.count} repositories"
      data.concat(current_page_repos.map do |repo|
        {
          github_id: repo.id,
          name: repo.name,
          data: repo.to_hash,
          created_at: repo.created_at,
          updated_at: repo.updated_at
        }
      end)

      break if current_page_repos.empty? || current_page_repos.count < 100
      page += 1
    end

    GithubRepo.upsert_all(data, unique_by: [:github_id])

    puts "Upserted #{data.count} repositories"
  end

  def sync_pull_requests
    data = []
    user_data = {}

    Parallel.each(GithubRepo.all, in_threads: 10) do |repo|
      repo_name = repo.data["full_name"]
      page = 1

      loop do
        begin
          current_page_prs = @client.pull_requests(repo_name, state: 'all', page: page, per_page: 100)
        rescue => e
          next if e.response_status == 404
          raise e
        end

        puts "Fetched #{current_page_prs.count} pull requests for #{repo_name}"
        data.concat(current_page_prs.map do |pr|
          pr.user.to_hash.tap do |data|
            user_data[pr.user.id] = {
              github_id: pr.user.id,
              login: pr.user.login,
              data: data
            }
          end

          {
            github_id: pr.id,
            title: pr.title,
            time_to_merge: pr.merged_at ? pr.merged_at - pr.created_at : nil,
            data: pr.to_hash,
            merged_at: pr.merged_at,
            created_at: pr.created_at,
            updated_at: pr.updated_at,
            github_repo_id: repo.github_id,
            github_user_id: pr.user.id
          }
        end)

        break if current_page_prs.empty? || current_page_prs.count < 100
        page += 1
      end
    end

    GithubPullRequest.upsert_all(data, unique_by: [:github_id])
    GithubUser.upsert_all(user_data.values, unique_by: [:github_id])

    puts "Upserted #{data.count} pull requests"
  end

  def sync_issues
    data = []
    user_data = {}

    Parallel.each(GithubRepo.all, in_threads: 10) do |repo|
      repo_name = repo.data["full_name"]
      page = 1

      loop do
        begin
          current_page_issues = @client.issues(repo_name, state: 'all', page: page, per_page: 100)
        rescue => e
          next if e.response_status == 404
          raise e
        end

        puts "Fetched #{current_page_issues.count} issues for #{repo_name}"
        data.concat(current_page_issues.map do |issue|
          issue.user.to_hash.tap do |data|
            user_data[issue.user.id] = {
              github_id: issue.user.id,
              login: issue.user.login,
              data: data
            }
          end

          {
            github_id: issue.id,
            github_node_id: issue.node_id,
            title: issue.title,
            data: issue.to_hash,
            created_at: issue.created_at,
            updated_at: issue.updated_at,
            github_repo_id: repo.github_id,
            github_user_id: issue.user.id
          }
        end)

        break if current_page_issues.empty? || current_page_issues.count < 100
        page += 1
      end
    end

    GithubIssue.upsert_all(data, unique_by: [:github_id])
    GithubUser.upsert_all(user_data.values, unique_by: [:github_id])

    puts "Upserted #{data.count} issues"
  end
end
