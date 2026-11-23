# Puma do serviço metrics: modo single (sem workers), 1 thread, porta 9394 no contêiner, sem porta no
# host. O rackup é o metrics.ru.
threads 1, 1
port ENV.fetch("PORT", 9394)
