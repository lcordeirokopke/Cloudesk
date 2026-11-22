"""Kafka do kit: produtor de eventos no tópico de entrada e consumidor das ações no tópico de saída.

- Inbound: cada evento vai com o valor no schema webhook.message-created, a chave conversation_id
  e os headers do schema kafka.inbound-headers, com acks="all". O tópico usa LogAppendTime; o
  timestamp devolvido na confirmação é o horário de gravação, que o agente deve devolver em
  timestamps.kafka_appended_at.
- Outbound: consumidor sem grupo, com todas as partições, começando do fim no momento da partida;
  separa as ações por conversation_id (valor da ação) e guarda chave, headers e timestamp.
"""

import asyncio
import json
from dataclasses import dataclass

from aiokafka import AIOKafkaConsumer, AIOKafkaProducer

LOG_APPEND_TIME = 1


@dataclass(frozen=True)
class Published:
    partition: int
    offset: int
    timestamp_ms: int


@dataclass(frozen=True)
class OutboundAction:
    value: dict
    key: bytes | None
    headers: dict[str, str]
    timestamp_ms: int


class InboundProducer:
    def __init__(self, brokers: str, topic: str):
        self.topic = topic
        self._producer = AIOKafkaProducer(bootstrap_servers=brokers, acks="all", enable_idempotence=True)

    async def start(self) -> None:
        await self._producer.start()

    async def stop(self) -> None:
        await self._producer.stop()

    async def publish(self, event: dict, headers: dict[str, str]) -> Published:
        metadata = await self._producer.send_and_wait(
            self.topic,
            value=json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            key=event["conversation_id"].encode("utf-8"),
            headers=[(name, value.encode("utf-8")) for name, value in headers.items()],
        )
        if metadata.timestamp_type != LOG_APPEND_TIME:
            raise RuntimeError(f"{self.topic} sem message.timestamp.type=LogAppendTime")
        return Published(metadata.partition, metadata.offset, metadata.timestamp)


class OutboundCollector:
    def __init__(self, brokers: str, topic: str):
        self.topic = topic
        self._consumer = AIOKafkaConsumer(topic, bootstrap_servers=brokers, group_id=None,
                                          enable_auto_commit=False, auto_offset_reset="latest")
        self._actions: dict[str, list[OutboundAction]] = {}
        self._changed = asyncio.Condition()
        self._task: asyncio.Task | None = None

    async def start(self, timeout: float = 30.0) -> None:
        """Parte do fim de cada partição; só volta com as posições resolvidas."""
        await self._consumer.start()
        async with asyncio.timeout(timeout):
            while not self._consumer.assignment():
                await asyncio.sleep(0.1)
        for partition in self._consumer.assignment():
            await self._consumer.position(partition)
        self._task = asyncio.create_task(self._collect())

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        await self._consumer.stop()

    def actions(self, conversation_id: str) -> list[OutboundAction]:
        return list(self._actions.get(conversation_id, []))

    async def wait(self, conversation_id: str, count: int, timeout: float) -> list[OutboundAction]:
        """Espera count ações da conversa; devolve as ações recebidas até o fim da espera."""
        async def enough():
            async with self._changed:
                await self._changed.wait_for(lambda: len(self._actions.get(conversation_id, [])) >= count)

        try:
            await asyncio.wait_for(enough(), timeout)
        except TimeoutError:
            pass
        return self.actions(conversation_id)

    async def _collect(self) -> None:
        async for record in self._consumer:
            try:
                value = json.loads(record.value)
            except (TypeError, ValueError):
                continue
            conversation_id = value.get("conversation_id") if isinstance(value, dict) else None
            if not isinstance(conversation_id, str):
                continue
            headers = {name: raw.decode("utf-8", errors="replace") for name, raw in record.headers or ()}
            async with self._changed:
                self._actions.setdefault(conversation_id, []).append(
                    OutboundAction(value, record.key, headers, record.timestamp))
                self._changed.notify_all()
