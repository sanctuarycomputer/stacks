class Api::ContactSerializer < ActiveModel::Serializer
  attributes :email, :sources, :metadata, :source_events
end
