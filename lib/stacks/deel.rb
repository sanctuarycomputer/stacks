class Stacks::Deel
  include HTTParty
  base_uri 'https://api.letsdeel.com/rest/v2'

  def initialize()
    @headers = {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Authorization": "Bearer #{Stacks::Utils.config[:deel][:api_key]}",
    }
  end

  def sync_all!
    ActiveRecord::Base.transaction do
    end
  end

  def get_people
    values = []

    response = self.class.get("/people?limit=200", headers: @headers)
    values = response["data"]
    page = response["page"]

    loop do
      break if page["items_per_page"] + page["offset"] >= page["total_rows"]
      response = self.class.get("/people?limit=200&offset=#{page["items_per_page"] + page["offset"]}", headers: @headers)
      values += response["data"]
      page = response["page"]
    end

    values
  end

  def get_contracts
    values = []

    response = self.class.get("/contracts?limit=150", headers: @headers)
    values = response["data"]
    page = response["page"]

    loop do
      break if page["cursor"].blank?
      response = self.class.get("/contracts?limit=150&after_cursor=#{page["cursor"]}", headers: @headers)
      values += response["data"]
      page = response["page"]
    end

    values
  end
end