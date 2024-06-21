class Stacks::Runn
  include HTTParty
  base_uri 'api.runn.io'

  def initialize()
    @headers = {
      "Accept": "application/json",
      "Accept-Version": "1.0.0",
      "Authorization": "Bearer #{Stacks::Utils.config[:runn][:api_token]}",
    }
  end

  def people
    self.class.get("/people", headers: @headers)
  end
end