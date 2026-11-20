"""Processamento de um registro de agent.inbound, do consumo à publicação da ação.

1. Carimba agent_consumed_at e lê o evento; registro inválido: invalid_event.
2. Marca sem locale em AGENT_BRAND_LOCALES: unknown_brand.
3. GET do contexto. Erro permanente: context_error. Erro transitório: nova tentativa
   (context_client), sem concluir o registro.
4. Mensagem do lojista no contexto com sequence maior que a do evento: discarded_newer.
5. Conversa fora de with_ai: discarded_state.
6. Decide pelo texto da mensagem com a sequence do evento (decision).
7. Espera AGENT_LATENCY_MS, carimba agent_published_at e publica em agent.outbound com a chave
   conversation_id e os headers brand e traceparent, aguardando a confirmação do Kafka. Falha na
   publicação: nova tentativa com a mesma pausa do contexto, com novo agent_published_at.

Todo resultado é final para o registro: o runner confirma o offset depois que handle termina.
"""

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from agent_mock import action, clock, decision, events, logs, trace
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
        except events.InvalidEvent as failure:
            return self._finish(logs.INVALID_EVENT, None, detail=str(failure), **position)

        fields = {"event_id": event.event_id, "conversation_id": event.conversation_id, "brand": event.brand,
                  "sequence": event.sequence, **position}

        locale = self.settings.brand_locales.get(event.brand)
        if locale is None:
            return self._finish(logs.UNKNOWN_BRAND, None, **fields)

        traceparent = str(trace.continue_trace(event.traceparent))
        try:
            context = await self.fetch_context(event, traceparent)
        except PermanentContextError as failure:
            return self._finish(logs.CONTEXT_ERROR, None, status=failure.status, detail=str(failure), **fields)

        newer = [message["sequence"] for message in context.get("messages", [])
                 if message.get("author") == "customer" and message.get("sequence", 0) > event.sequence]
        if newer:
            return self._finish(logs.DISCARDED_NEWER, None, last_customer_sequence=max(newer), **fields)

        state = context["conversation"].get("state")
        if state != "with_ai":
            return self._finish(logs.DISCARDED_STATE, None, state=state, **fields)

        chosen = decision.decide(event, context, locale, self.stamp)
        if self.settings.latency_ms > 0:
            await self.sleep(self.settings.latency_ms / 1000)

        published = await self._publish(event, chosen, traceparent, consumed_at, fields)
        return self._finish(logs.PUBLISHED, published, action=published["type"],
                            idempotency_key=action.idempotency_key(published), traceparent=traceparent, **fields)

    async def _publish(self, event, chosen, traceparent, consumed_at, fields) -> dict:
        for delay in backoff_delays():
            built = action.build(event, chosen, traceparent=traceparent, consumed_at=consumed_at,
                                 published_at=self.stamp())
            headers = [(name, value.encode("utf-8")) for name, value in action.headers(built).items()]
            try:
                await self.publish(event.conversation_id.encode("utf-8"), action.encode(built), headers)
                return built
            except Exception as failure:
                logs.warning("publicação sem confirmação do Kafka", retry_in_seconds=delay,
                             detail=f"{type(failure).__name__}: {failure}", **fields)
                await self.sleep(delay)
        raise AssertionError("backoff_delays é infinito")

    @staticmethod
    def _finish(result: str, published: dict | None, **fields) -> Outcome:
        level = logs.info if result in (logs.PUBLISHED, logs.DISCARDED_NEWER, logs.DISCARDED_STATE) else logs.warning
        level("evento processado", result=result, **fields)
        return Outcome(result, published)
