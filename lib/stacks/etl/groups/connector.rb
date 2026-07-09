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

        # No exclusion override: public list addresses -> inherit the base default
        # [:not_excluded, :none]. Manual include/exclude still works via human_locked?.
      end
    end
  end
end
