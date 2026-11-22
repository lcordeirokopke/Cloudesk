"""Consumidor do tópico de entrada e produtor do tópico de saída, com concorrência por conversa.

Os tópicos vêm de Settings (AGENT_INBOUND_TOPIC e AGENT_OUTBOUND_TOPIC, com padrão agent.inbound e
agent.outbound).

- AIOKafkaConsumer no grupo AGENT_GROUP_ID, com enable_auto_commit=False e
  auto_offset_reset="earliest"; AIOKafkaProducer com acks="all" e enable_idempotence=True.
- Cada registro lido vira uma tarefa encadeada à anterior da mesma conversa (chave do registro):
  em série dentro da conversa, em paralelo entre conversas. O semáforo de AGENT_CONCURRENCY
  limita as tarefas em andamento e segura a leitura quando cheio.
- OffsetTracker guarda, por partição, os offsets lidos e os concluídos; o offset confirmado é o
  do primeiro registro lido e não concluído, ou o último concluído + 1. Um registro em andamento
  segura a confirmação dos posteriores, mesmo concluídos.
- A confirmação roda a cada segundo, no fim do processo e no on_partitions_revoked, que espera as
  tarefas das partições revogadas antes de confirmar.
- Queda do processo: os registros sem offset confirmado são relidos; a ação republicada tem a
  mesma Idempotency-Key e o Core deduplica.
"""

import asyncio
from collections import deque
from collections.abc import Awaitable, Callable, Hashable

import aiohttp
from aiokafka import AIOKafkaConsumer, AIOKafkaProducer, TopicPartition
from aiokafka.abc import ConsumerRebalanceListener

from agent_mock import logs
from agent_mock.config import Settings
from agent_mock.context_client import ContextClient
from agent_mock.processor import Processor

COMMIT_INTERVAL_SECONDS = 1.0
SHUTDOWN_GRACE_SECONDS = 5.0


class OffsetTracker:
    """Offsets lidos e concluídos por partição; devolve o próximo offset a confirmar."""

    def __init__(self):
        self._pending: dict[Hashable, deque[int]] = {}
        self._done: dict[Hashable, set[int]] = {}
        self._ready: dict[Hashable, int] = {}
        self._committed: dict[Hashable, int] = {}

    def started(self, partition: Hashable, offset: int) -> None:
        self._pending.setdefault(partition, deque()).append(offset)
        self._done.setdefault(partition, set())

    def finished(self, partition: Hashable, offset: int) -> None:
        if partition not in self._pending:
            return
        self._done[partition].add(offset)
        pending, done = self._pending[partition], self._done[partition]
        while pending and pending[0] in done:
            first = pending.popleft()
            done.discard(first)
            self._ready[partition] = first + 1

    def commits(self) -> dict[Hashable, int]:
        """Offsets a confirmar que avançaram desde a última confirmação registrada."""
        return {partition: offset for partition, offset in self._ready.items()
                if self._committed.get(partition) != offset}

    def committed(self, offsets: dict[Hashable, int]) -> None:
        self._committed.update(offsets)

    def forget(self, partition: Hashable) -> None:
        for table in (self._pending, self._done, self._ready, self._committed):
            table.pop(partition, None)


class Scheduler:
    """Tarefas em série por conversa e em paralelo entre conversas, limitadas pelo semáforo."""

    def __init__(self, concurrency: int, tracker: OffsetTracker):
        self.semaphore = asyncio.Semaphore(concurrency)
        self.tracker = tracker
        self._last_by_key: dict[Hashable, asyncio.Task] = {}
        self._by_partition: dict[Hashable, set[asyncio.Task]] = {}
        self.failure: BaseException | None = None

    async def submit(self, partition: Hashable, offset: int, key: Hashable | None,
                     work: Callable[[], Awaitable[object]],
                     accept: Callable[[], bool] = lambda: True) -> asyncio.Task | None:
        """Agenda o trabalho do registro; espera vaga no semáforo antes de agendar.

        accept é conferido depois da espera: devolvendo False (partição revogada ou parada), o
        registro não é agendado e será relido por quem ficar com a partição.
        """
        await self.semaphore.acquire()
        if not accept():
            self.semaphore.release()
            return None
        self.tracker.started(partition, offset)
        previous = self._last_by_key.get(key) if key is not None else None
        task = asyncio.create_task(self._run(partition, offset, previous, work))
        if key is not None:
            self._last_by_key[key] = task
        tasks = self._by_partition.setdefault(partition, set())
        tasks.add(task)
        task.add_done_callback(lambda done: self._cleanup(partition, key, done))
        return task

    async def _run(self, partition, offset, previous, work):
        try:
            if previous is not None:
                await asyncio.wait([previous])
            await work()
            self.tracker.finished(partition, offset)
        except asyncio.CancelledError:
            raise
        except Exception as failure:
            self.failure = failure
            logs.error("falha inesperada no processamento; o agente para", partition=str(partition), offset=offset,
                       detail=f"{type(failure).__name__}: {failure}")
        finally:
            self.semaphore.release()

    def _cleanup(self, partition, key, task):
        self._by_partition.get(partition, set()).discard(task)
        if key is not None and self._last_by_key.get(key) is task:
            del self._last_by_key[key]

    async def wait_partitions(self, partitions) -> None:
        tasks = set().union(*(self._by_partition.get(partition, set()) for partition in partitions))
        if tasks:
            await asyncio.wait(tasks)

    def tasks(self) -> set[asyncio.Task]:
        return set().union(*self._by_partition.values()) if self._by_partition else set()


class Runner:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.tracker = OffsetTracker()
        self.scheduler = Scheduler(settings.concurrency, self.tracker)
        self.assigned: set[TopicPartition] = set()
        self.stopping = asyncio.Event()
        self.consumer: AIOKafkaConsumer | None = None
        self.producer: AIOKafkaProducer | None = None

    def stop(self) -> None:
        self.stopping.set()

    async def commit(self, partitions=None) -> None:
        offsets = {partition: offset for partition, offset in self.tracker.commits().items()
                   if partitions is None or partition in partitions}
        if not offsets:
            return
        try:
            await self.consumer.commit(offsets)
            self.tracker.committed(offsets)
        except Exception as failure:
            logs.warning("confirmação de offsets recusada", detail=f"{type(failure).__name__}: {failure}")

    async def on_revoked(self, revoked) -> None:
        revoked = set(revoked)
        self.assigned -= revoked
        await self.scheduler.wait_partitions(revoked)
        await self.commit(revoked)
        for partition in revoked:
            self.tracker.forget(partition)
        logs.info("partições revogadas", partitions=sorted(f"{p.topic}/{p.partition}" for p in revoked))

    async def on_assigned(self, assigned) -> None:
        self.assigned |= set(assigned)
        logs.info("partições atribuídas", partitions=sorted(f"{p.topic}/{p.partition}" for p in assigned))

    async def run(self) -> None:
        settings = self.settings
        self.consumer = AIOKafkaConsumer(
            bootstrap_servers=settings.kafka_brokers, group_id=settings.group_id,
            enable_auto_commit=False, auto_offset_reset="earliest",
        )
        self.producer = AIOKafkaProducer(
            bootstrap_servers=settings.kafka_brokers, acks="all", enable_idempotence=True,
        )
        self.consumer.subscribe([settings.inbound_topic], listener=_Listener(self))
        await self.producer.start()
        await self.consumer.start()
        session = aiohttp.ClientSession()
        client = ContextClient(session, settings)

        async def fetch_context(event, traceparent):
            def on_retry(failure, delay):
                logs.warning("contexto indisponível; nova tentativa", event_id=event.event_id,
                             conversation_id=event.conversation_id, brand=event.brand, retry_in_seconds=delay,
                             detail=str(failure))
            return await client.fetch(event, traceparent, on_retry=on_retry)

        processor = Processor(settings, fetch_context, self.publish)
        committer = asyncio.create_task(self._commit_periodically())
        logs.info("agente iniciado", group_id=settings.group_id, concurrency=settings.concurrency,
                  latency_ms=settings.latency_ms, inbound_topic=settings.inbound_topic,
                  outbound_topic=settings.outbound_topic)
        try:
            await self._consume(processor)
        finally:
            committer.cancel()
            await self._drain()
            await self.commit()
            await self.consumer.stop()
            await self.producer.stop()
            await session.close()
            logs.info("agente parado")
        if self.scheduler.failure is not None:
            raise SystemExit(1)

    async def publish(self, key: bytes, value: bytes, headers: list[tuple[str, bytes]]):
        return await self.producer.send_and_wait(self.settings.outbound_topic, value=value, key=key, headers=headers)

    async def _consume(self, processor: Processor) -> None:
        while not self.stopping.is_set() and self.scheduler.failure is None:
            batches = await self.consumer.getmany(timeout_ms=1000)
            for partition, records in batches.items():
                accept = lambda partition=partition: (
                    partition in self.assigned and not self.stopping.is_set() and self.scheduler.failure is None)
                for record in records:
                    if not accept():
                        break
                    await self.scheduler.submit(partition, record.offset, record.key,
                                                lambda record=record: processor.handle(record), accept)

    async def _drain(self) -> None:
        tasks = self.scheduler.tasks()
        if not tasks:
            return
        _done, pending = await asyncio.wait(tasks, timeout=SHUTDOWN_GRACE_SECONDS)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.wait(pending)
            logs.warning("eventos interrompidos na parada; serão relidos", count=len(pending))

    async def _commit_periodically(self) -> None:
        while True:
            await asyncio.sleep(COMMIT_INTERVAL_SECONDS)
            await self.commit(self.assigned)


class _Listener(ConsumerRebalanceListener):
    def __init__(self, runner: Runner):
        self.runner = runner

    async def on_partitions_revoked(self, revoked):
        await self.runner.on_revoked(revoked)

    async def on_partitions_assigned(self, assigned):
        await self.runner.on_assigned(assigned)
