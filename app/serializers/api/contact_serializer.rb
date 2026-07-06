class Api::ContactSerializer < ActiveModel::Serializer
  attributes :email, :sources, :metadata
end
