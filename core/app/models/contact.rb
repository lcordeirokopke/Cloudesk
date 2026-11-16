# Lojista sintético, com identidades por canal.
class Contact < ApplicationRecord
  include BrandScoped

  has_many :identities, class_name: "ContactIdentity"
  has_many :conversations
  has_one :customer_memory

  validates :name, :locale, presence: true
end
