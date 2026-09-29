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

        # Lists whose mail regularly carries one person's pay, hiring or HR matters, matched on the
        # list's local part in ANY of the org's domains (jobs@xxix.co too). Their BODIES are
        # content-reviewed; every other list is screened on the subject only (51k threads).
        SCREENED_LISTS = %w[jobs admin accounting payroll hr people hiring].freeze
        # Once a thread is seen on a screened list it stays screened: a thread cross-posted to
        # jobs@ and another list is one Document, and whichever crawl ran last must not undo it.
        SCREENED_KEY = 'privacy_screened'.freeze

        def preserved_metadata_keys = super + [SCREENED_KEY]

        # Explicit privacy policy (the base connector is default-deny). Group mail goes to a list,
        # so it is never a 1:1, but a thread whose SUBJECT names a sensitive topic (salary, HR,
        # termination, …) is walled off exactly as a meeting with that title would be. Threads seen
        # on a screened list then go through the content review. Manual include/exclude still
        # works via human_locked?.
        def exclusion_for(normalized, doc = nil)
          titled = Stacks::Etl::Classifier.title_exclusion(normalized[:title])
          return titled if titled
          meta = doc&.raw_metadata || normalized[:raw_metadata]
          return [:not_excluded, :none] unless self.class.screened?(meta)
          doc.raw_metadata = (doc.raw_metadata || {}).merge(SCREENED_KEY => true) if doc
          Stacks::Etl::ContentReview.call(doc: doc, text: Stacks::Etl::ContentReview.text_of(normalized[:segments]),
                                          content_hash: normalized[:content_hash] || doc&.content_hash)
        end

        def self.screened?(raw_metadata)
          meta = raw_metadata.to_h
          return true if meta[SCREENED_KEY]
          SCREENED_LISTS.include?(meta['group_email'].to_s.downcase.split('@').first)
        end
      end
    end
  end
end
