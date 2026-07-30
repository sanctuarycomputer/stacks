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

      matches = @runn.get_people.select do |p|
        !p["isArchived"] && p["email"].to_s.strip.downcase == email
      end
      matches.one? ? matches.first["id"] : nil
    end
  end
end
