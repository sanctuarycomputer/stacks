class Api::ProfitSharePassSerializer 
  include JSONAPI::Serializer
  attributes :id, :snapshot, :total_psu_issued

  def total_psu_issued
    object.total_psu_issued.round
  end
end
