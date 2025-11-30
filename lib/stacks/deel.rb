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
      DeelOffCyclePayment.delete_all
      DeelContract.delete_all
      DeelPerson.delete_all
      sync_people!
      sync_contracts!

      # TODO: Parallelize this
      DeelContract.all.each do |dc|
        sync_off_cycle_payments!(dc.deel_id)
      end
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
      raise response unless response.success?
      values += response["data"]
      page = response["page"]
    end

    values
  end

  def sync_people!
    data = get_people.map do |p|
      {
        deel_id: p["id"],
        data: p,
      }
    end
    DeelPerson.upsert_all(data, unique_by: :deel_id)
  end

  def get_contracts
    values = []

    response = self.class.get("/contracts?limit=150", headers: @headers)
    values = response["data"]
    page = response["page"]

    loop do
      break if page["cursor"].blank?
      response = self.class.get("/contracts?limit=150&after_cursor=#{page["cursor"]}", headers: @headers)
      raise response unless response.success?
      values += response["data"]
      page = response["page"]
    end

    values
  end

  def sync_contracts!
    data = get_contracts.map do |c|
      next nil if c.dig("worker", "id").nil?
      {
        deel_id: c["id"],
        deel_person_id: c.dig("worker", "id"),
        data: c,
      }
    end.compact
    DeelContract.upsert_all(data, unique_by: :deel_id)
  end

  def get_off_cycle_payments(contract_id)
    response = self.class.get("/contracts/#{contract_id}/off-cycle-payments", headers: @headers)
    raise response unless response.success?
    response["data"]
  end

  def sync_off_cycle_payments!(contract_id)
    puts "Syncing off cycle payments for #{contract_id}"
    data = get_off_cycle_payments(contract_id).map do |op|
      {
        deel_id: op["id"],
        deel_contract_id: contract_id,
        data: op,
        created_at: op["created_at"],
        submitted_at: op["date_submitted"],
      }
    end
    DeelOffCyclePayment.upsert_all(data, unique_by: :deel_id) unless data.empty?
  end
end