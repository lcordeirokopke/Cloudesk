# Job mínimo usado para provar que o Solid Queue grava o job na base do app e o executa.
class SmokeJob < ApplicationJob
  queue_as :default

  def perform(token)
    Rails.logger.info("SmokeJob executado: #{token}")
  end
end
