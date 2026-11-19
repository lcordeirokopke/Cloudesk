class ApplicationJob < ActiveJob::Base
  # Backoff exponencial com jitter das novas tentativas, usado no wait dos retry_on: 2^n segundos
  # mais até 15%, em que n é o número de execuções já feitas. Com 10 tentativas, as esperas somam
  # cerca de 17 minutos até a fila de falhas.
  BACKOFF_JITTER = 0.15
  EXPONENTIAL_BACKOFF = ->(executions) { (2**executions) * (1 + (rand * BACKOFF_JITTER)) }
end
