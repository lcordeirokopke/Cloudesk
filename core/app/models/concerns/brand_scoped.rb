# Comportamento comum aos models de domínio: toda linha pertence a uma marca, e a marca de uma
# linha nova é a do bloco Tenancy.with_brand corrente.
module BrandScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :brand

    before_validation :assign_current_brand, on: :create
  end

  private

  def assign_current_brand
    self.brand_id ||= Tenancy.current_brand_id
  end
end
