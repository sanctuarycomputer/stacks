module Stacks
  module Etl
    module Meet
      class Connector < Stacks::Etl::Connector
        def initialize(admin_email:, mode: :api, since: nil)
          @admin_email = admin_email
          @mode = mode
          @since = since
        end

        def source = :meet

        def extract(since:)
          docs = []
          source_object(since || @since).each_meeting { |n| docs << n }
          docs
        end

        def exclusion_for(normalized)
          Classifier.call(title: normalized[:title], participant_count: normalized[:contacts].size)
        end

        private

        def source_object(since)
          if @mode == :drive
            DriveSource.new(@admin_email, since: since || 90.days.ago)
          else
            MeetApiSource.new(@admin_email, since: since)
          end
        end
      end
    end
  end
end
