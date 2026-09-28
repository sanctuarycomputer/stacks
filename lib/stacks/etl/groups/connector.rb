module Stacks
  module Etl
    module Groups
      class Connector < Stacks::Etl::Connector
        def initialize(admin_email:, since: nil, until_time: nil, k: 2)
          @admin_email = admin_email
          @since = since
          @until_time = until_time
          @k = k
        end

        def source = :google_groups

        def extract(since:)
          src = GroupsSource.new(admin_email: @admin_email, since: since || @since,
                                 until_time: @until_time, k: @k)
          # Lazy: assemble + ingest one group's threads at a time, not the whole org.
          Enumerator.new { |y| src.each_thread { |n| y << n } }
        end

        # Explicit privacy policy (the base connector is default-deny). Group mail goes to a list,
        # so it is never a 1:1, but a thread whose SUBJECT names a sensitive topic (salary, HR,
        # termination, …) is walled off exactly as a meeting with that title would be. Bodies are
        # not content-reviewed (51k threads); manual include/exclude still works via human_locked?.
        def exclusion_for(normalized, _doc = nil)
          Stacks::Etl::Classifier.title_exclusion(normalized[:title]) || [:not_excluded, :none]
        end
      end
    end
  end
end
