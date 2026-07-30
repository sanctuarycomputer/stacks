module Resourcing
  # The Runn adapter seam: resolves a Contributor to its Runn person id by email
  # (Contributor -> forecast_person -> email, matched against live Runn people).
  # When Runn is deprecated, this is the piece that changes/disappears.
  class RunnPersonResolver
    def initialize(runn)
      @runn = runn
    end

    def runn_person_id_for(contributor)
      email = contributor&.forecast_person&.email.to_s.strip.downcase
      return nil if email.blank?

      matches = people.select do |p|
        !p["isArchived"] && p["email"].to_s.strip.downcase == email
      end
      matches.one? ? matches.first["id"] : nil
    end

    private

    # Memoized: people don't change mid-sweep, so a batch that reuses one resolver
    # fetches the (paginated) people list once, not once per item. Assignments are
    # deliberately NOT cached — CAS re-reads them live on every apply.
    def people
      @people ||= @runn.get_people
    end
  end
end
