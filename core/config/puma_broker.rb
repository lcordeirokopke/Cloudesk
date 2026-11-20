# Puma do broker-web: modo single (sem workers), 5 threads, porta 3000 no contêiner.
# O rackup é o broker.ru, sem Rails.
threads 5, 5
port ENV.fetch("PORT", 3000)

# Fecha o produtor Kafka ao parar: as mensagens ainda na fila local são entregues antes da saída.
after_stopped do
  BROKER_PRODUCER.close if defined?(BROKER_PRODUCER)
end
