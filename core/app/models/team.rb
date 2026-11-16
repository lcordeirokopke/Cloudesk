# Equipe de analistas, com skills e horário.
class Team < ApplicationRecord
  include BrandScoped

  has_many :queues, class_name: "Routing::Queue"
  has_many :attendants

  validates :name, presence: true
end
