require_relative "task_builder/discoveries/base"
require_relative "task_builder/discoveries/project_trackers"
require_relative "task_builder/discoveries/forecast_projects"
require_relative "task_builder/discoveries/forecast_people"
require_relative "task_builder/discoveries/forecast_assignments"
require_relative "task_builder/discoveries/admin_users"
require_relative "task_builder/discoveries/reimbursements"
require_relative "task_builder/discoveries/notion_leads"
require_relative "task_builder/discoveries/surveys"

module Stacks
  # Single source of truth for "what needs attention right now" across the system.
  # Replaces the previous Stacks::DataIntegrityManager — combines its discoveries
  # with survey-response gaps and routes every task to one or more AdminUsers
  # (always falling back to AdminUser.admin so no task is unowned).
  #
  # AdminUser#pending_tasks calls .tasks_for(user) and filters to the per-user
  # view. The /admin/tasks dashboard renders the full set.
  #
  # ── Cache shape ───────────────────────────────────────────────────────────
  # We deliberately do NOT cache the full Array<StacksTask>. Subject records
  # can be heavy (e.g. NotionPage.data jsonb), and serializing+deserializing
  # them on every page load adds noticeable latency. Instead we cache a flat
  # Array<Hash> of descriptors:
  #
  #   { subject_type: "ProjectTracker",
  #     subject_id:   123,
  #     type:         :project_capsule_incomplete,
  #     owner_ids:    [1, 4, 9] }
  #
  # On read, we batch-load subjects (one query per unique subject class) and
  # admin users (one query total), then construct StacksTask objects fresh.
  # tasks_for(user) further short-circuits by filtering descriptors before
  # hydration — only the per-user subset gets loaded.
  class TaskBuilder
    CACHE_KEY = "Stacks::TaskBuilder#descriptors".freeze
    CACHE_TTL = 24.hours

    DISCOVERY_CLASSES = [
      Discoveries::ProjectTrackers,
      Discoveries::ForecastProjects,
      Discoveries::ForecastPeople,
      Discoveries::ForecastAssignments,
      Discoveries::AdminUsers,
      Discoveries::Reimbursements,
      Discoveries::NotionLeads,
      Discoveries::Surveys,
    ].freeze

    # Returns Array<StacksTask> — every open task system-wide.
    def tasks
      hydrate(cached_descriptors)
    end

    # Returns Array<StacksTask> assigned to the given AdminUser. Filters
    # descriptors BEFORE hydration so unrelated subjects never get loaded.
    def tasks_for(admin_user)
      return [] unless admin_user&.id
      relevant = cached_descriptors.select { |d| d[:owner_ids].include?(admin_user.id) }
      hydrate(relevant)
    end

    # Total count across the system. Cheap — just a length on the cached
    # descriptor array, no hydration.
    def task_count
      cached_descriptors.length
    end

    def refresh!
      Rails.cache.delete(CACHE_KEY)
      cached_descriptors
    end

    # Drops the cache without rebuilding. The next call to .tasks /
    # .tasks_for / .task_count will trigger a fresh build. Used by the
    # BustsTaskCache concern via after_commit hooks — a burst of saves in
    # one transaction only causes one rebuild on the next read.
    def self.clear_cache!
      Rails.cache.delete(CACHE_KEY)
    end

    private

    def cached_descriptors
      @_cached_descriptors ||= Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        build_tasks.map { |t| descriptor_for(t) }
      end
    end

    def descriptor_for(task)
      {
        subject_type: task.subject.class.name,
        subject_id: subject_id_for(task.subject),
        type: task.type,
        owner_ids: task.owners.map(&:id),
      }
    end

    def subject_id_for(subject)
      case subject
      when Stacks::Notion::Lead then subject.notion_page.id
      else subject.id
      end
    end

    # Hydrate descriptors → StacksTask. Bounded by O(unique subject classes)
    # SELECTs + 1 SELECT for AdminUsers, regardless of how many tasks.
    def hydrate(descriptors)
      return [] if descriptors.empty?

      subjects = batch_load_subjects(descriptors)
      admins = batch_load_admins(descriptors)

      descriptors.map do |d|
        subject = subjects.dig(d[:subject_type], d[:subject_id])
        # Subject may have been deleted between cache write and hydrate. Skip.
        next nil unless subject

        owners = d[:owner_ids].map { |id| admins[id] }.compact
        # All owners deleted (extreme edge). Skip rather than violate the
        # StacksTask "must have ≥1 owner" invariant.
        next nil if owners.empty?

        StacksTask.new(type: d[:type], subject: subject, owners: owners)
      end.compact
    end

    def batch_load_subjects(descriptors)
      descriptors.group_by { |d| d[:subject_type] }.each_with_object({}) do |(type_name, ds), acc|
        ids = ds.map { |d| d[:subject_id] }.uniq
        klass = type_name.safe_constantize
        next unless klass

        records =
          if klass == Stacks::Notion::Lead
            # Lead is a wrapper around NotionPage; load the underlying pages
            # and re-wrap. Index by NotionPage.id so descriptor lookup matches.
            NotionPage.where(id: ids).index_by(&:id).transform_values(&:as_lead)
          else
            # Use the model's declared primary_key so this works for models
            # with non-default PKs (ForecastProject uses forecast_id, etc.).
            klass.where(klass.primary_key => ids).index_by(&:id)
          end
        acc[type_name] = records
      end
    end

    def batch_load_admins(descriptors)
      ids = descriptors.flat_map { |d| d[:owner_ids] }.uniq
      return {} if ids.empty?
      AdminUser.where(id: ids).index_by(&:id)
    end

    def build_tasks
      admin_fallback = AdminUser.admin.to_a
      DISCOVERY_CLASSES.flat_map do |klass|
        klass.new(admin_fallback: admin_fallback).tasks
      rescue => e
        Rails.logger.error("TaskBuilder discovery failed in #{klass.name}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        []
      end.compact
    end
  end
end
