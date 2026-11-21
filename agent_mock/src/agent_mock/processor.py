"""Processamento de um registro de agent.inbound, do consumo à publicação da ação.

1. Carimba agent_consumed_at e lê o evento; registro inválido: invalid_event.
2. Marca sem locale em AGENT_BRAND_LOCALES: unknown_brand.
3. GET do contexto. Erro permanente: context_error. Erro transitório: nova tentativa
   (context_client), sem concluir o registro.
4. Mensagem do lojista no contexto com sequence maior que a do evento: discarded_newer.
5. Conversa fora de with_ai: discarded_state.
6. Decide pelo texto da mensagem com a sequence do evento e pela memória do lojista no contexto,
   com a janela AGENT_MEMORY_WINDOW_DAYS (decision).
7. Espera AGENT_LATENCY_MS, carimba agent_published_at e publica em agent.outbound com a chave
   conversation_id e os headers brand e traceparent, aguardando a confirmação do Kafka. Falha na
   publicação: nova tentativa com a mesma pausa do contexto, com novo agent_published_at.

Modo de falha (AGENT_FAILURE_MODE), só no evento afetado (failure.affected, pelo event_id e por
AGENT_FAILURE_RATE), depois da decisão:
- delay: soma AGENT_FAILURE_DELAY_MS à latência antes da publicação;
- drop: termina sem publicar (failure_drop);
- duplicate: publica a mesma ação duas vezes, cada uma aguardando a confirmação do Kafka;
- stale: publica a ação com based_on_sequence igual à sequence do evento menos 1; com sequence 1,
  publica a ação sem alteração (failure_stale_skipped).

Todo resultado é final para o registro: o runner confirma o offset depois que handle termina.
"""

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from agent_mock import action, clock, decision, events, failure, logs, trace
from agent_mock.config import Settings
from agent_mock.context_client import PermanentContextError, backoff_delays

Publish = Callable[[bytes, bytes, list[tuple[str, bytes]]], Awaitable[object]]
FetchContext = Callable[[events.Event, str], Awaitable[dict]]


@dataclass(frozen=True)
class Outcome:
    result: str
    action: dict | None = None


class Processor:
    def __init__(self, settings: Settings, fetch_context: FetchContext, publish: Publish,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep, stamp: Callable[[], str] = clock.stamp):
        self.settings = settings
        self.fetch_context = fetch_context
        self.publish = publish
        self.sleep = sleep
        self.stamp = stamp

    async def handle(self, record) -> Outcome:
        consumed_at = self.stamp()
        position = {"partition": record.partition, "offset": record.offset}

        try:
            event = events.parse(record)
        except events.InvalidEvent as error:
            return self._finish(logs.INVALID_EVENT, None, detail=str(error), **position)

        fields = {"event_id": event.event_id, "conversation_id": event.conversation_id, "brand": event.brand,
                  "sequence": event.sequence, **position}

        locale = self.settings.brand_locales.get(event.brand)
        if locale is None:
            return self._finish(logs.UNKNOWN_BRAND, None, **fields)

        traceparent = str(trace.continue_trace(event.traceparent))
        try:
            context = await self.fetch_context(event, traceparent)
        except PermanentContextError as error:
            return self._finish(logs.CONTEXT_ERROR, None, status=error.status, detail=str(error), **fields)

        newer = [message["sequence"] for message in context.get("messages", [])
                 if message.get("author") == "customer" and message.get("sequence", 0) > event.sequence]
        if newer:
            return self._finish(logs.DISCARDED_NEWER, None, last_customer_sequence=max(newer), **fields)

        state = context["conversation"].get("state")
        if state != "with_ai":
            return self._finish(logs.DISCARDED_STATE, None, state=state, **fields)

        chosen = decision.decide(event, context, locale, self.stamp,
                                 memory_window_days=self.settings.memory_window_days)

        mode = self.settings.failure_mode
        if mode == "none" or not failure.affected(event.event_id, self.settings.failure_rate):
            mode = None
        if mode == "drop":
            return self._finish(logs.FAILURE_DROP, None, action=chosen.type, failure=mode, **fields)

        latency_ms = self.settings.latency_ms + (self.settings.failure_delay_ms if mode == "delay" else 0)
        if latency_ms > 0:
            await self.sleep(latency_ms / 1000)

        result = logs.PUBLISHED
        based_on_sequence = event.sequence
        if mode == "stale":
            if event.sequence > 1:
                based_on_sequence = event.sequence - 1
            else:
                result = logs.FAILURE_STALE_SKIPPED

        published = await self._publish(event, chosen, traceparent, consumed_at, fields, based_on_sequence)
        if mode == "duplicate":
            await self._send(event, published, fields)
        return self._finish(result, published, action=published["type"], failure=mode,
                            idempotency_key=action.idempotency_key(published), traceparent=traceparent, **fields)

    async def _publish(self, event, chosen, traceparent, consumed_at, fields, based_on_sequence) -> dict:
        def build() -> dict:
            built = action.build(event, chosen, traceparent=traceparent, consumed_at=consumed_at,
                                 published_at=self.stamp())
            built["based_on_sequence"] = based_on_sequence
            return built

        return await self._send(event, build, fields)

    async def _send(self, event, built, fields) -> dict:
        """Publica a ação até a confirmação do Kafka. built é a ação pronta, publicada sem alteração,
        ou uma função que monta a ação a cada tentativa, com novo agent_published_at."""
        for delay in backoff_delays():
            current = built() if callable(built) else built
            headers = [(name, value.encode("utf-8")) for name, value in action.headers(current).items()]
            try:
                await self.publish(event.conversation_id.encode("utf-8"), action.encode(current), headers)
                return current
            except Exception as error:
                logs.warning("publicação sem confirmação do Kafka", retry_in_seconds=delay,
                             detail=f"{type(error).__name__}: {error}", **fields)
                await self.sleep(delay)
        raise AssertionError("backoff_delays é infinito")

    @staticmethod
    def _finish(result: str, published: dict | None, **fields) -> Outcome:
        level = logs.info if result in (logs.PUBLISHED, logs.DISCARDED_NEWER, logs.DISCARDED_STATE,
                                        logs.FAILURE_DROP, logs.FAILURE_STALE_SKIPPED) else logs.warning
        level("evento processado", result=result, **fields)
        return Outcome(result, published)
