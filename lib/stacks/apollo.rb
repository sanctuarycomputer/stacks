class Stacks::Apollo
  include HTTParty
  base_uri 'https://api.apollo.io/v1'

  def initialize()
    @headers = {
      "X-Api-Key": "#{Stacks::Utils.config[:apollo][:api_key]}",
      "Cache-Control" => "no-cache",
      "Content-Type" => "application/json"
    }
  end

  def get_health
    self.class.get("/auth/health", headers: @headers)
  end

  def create_contact(email)
    self.class.post("/contacts", {
      body: JSON.dump({ "email": email }),
      headers: @headers
    })["contact"]
  end

  def search_by_email(email)
    resp = self.class.post("/contacts/search", {
      body: JSON.dump({ "q_keywords": email }),
      headers: @headers
    })
    resp.parsed_response["contacts"]
  end
end

