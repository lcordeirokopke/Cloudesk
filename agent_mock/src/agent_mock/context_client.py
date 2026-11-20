"""Leitura do contexto da conversa no Core: GET {CORE_URL}{context_url}.

A chamada é assinada com AGENT_CONTEXT_SECRET (signature.headers, método GET, caminho da
context_url, corpo vazio) e leva o header traceparent do salto do agente.

| Resultado | Casos | Tratamento |
| - | - | - |
| ok | 200 com objeto JSON com conversation e messages | devolve o contexto |
| permanente | 401, 404, 422 e demais 4xx; 200 com corpo fora do formato; 3xx | PermanentContextError |
| transitório | erro de rede, timeout, 408, 429 e 5xx | nova tentativa |

As novas tentativas esperam 2 s, dobram a cada vez e param de crescer em 60 s, sem limite de
tentativas.
"""

import asyncio
import json
import time
from collections.abc import Awaitable, Callable, Iterator

import aiohttp

from agent_mock import signature
from agent_mock.config import Settings
from agent_mock.events import Event

RETRY_STATUSES = {408, 429}
FIRST_DELAY_SECONDS = 2.0
MAX_DELAY_SECONDS = 60.0


class PermanentContextError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"{status}: {message}")
        self.status = status


class TransientContextError(Exception):
    pass


def backoff_delays() -> Iterator[float]:
    """Pausas das novas tentativas: 2 s, exponencial, até 60 s."""
    delay = FIRST_DELAY_SECONDS
    while True:
        yield delay
        delay = min(delay * 2, MAX_DELAY_SECONDS)


class ContextClient:
    def __init__(self, session: aiohttp.ClientSession, settings: Settings,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep, now: Callable[[], float] = time.time):
        self.session = session
        self.settings = settings
        self.sleep = sleep
        self.now = now

    async def fetch(self, event: Event, traceparent: str,
                    on_retry: Callable[[Exception, float], None] | None = None) -> dict:
        """Contexto do evento, repetindo as falhas transitórias. Erro permanente lança PermanentContextError."""
        for delay in backoff_delays():
            try:
                return await self.fetch_once(event, traceparent)
            except TransientContextError as failure:
                if on_retry:
                    on_retry(failure, delay)
                await self.sleep(delay)
        raise AssertionError("backoff_delays é infinito")

    async def fetch_once(self, event: Event, traceparent: str) -> dict:
        path = event.context_url
        headers = signature.headers(self.settings.context_secret, "GET", path, "", now=self.now())
        headers["traceparent"] = traceparent
        timeout = aiohttp.ClientTimeout(total=self.settings.context_timeout_seconds)
        try:
            async with self.session.get(f"{self.settings.core_url}{path}", headers=headers, timeout=timeout,
                                        allow_redirects=False) as response:
                status = response.status
                text = await response.text()
        except (aiohttp.ClientError, asyncio.TimeoutError) as failure:
            raise TransientContextError(f"falha de rede: {type(failure).__name__}: {failure}") from failure

        if status in RETRY_STATUSES or status >= 500:
            raise TransientContextError(f"{status}: {text[:200]}")
        if status != 200:
            raise PermanentContextError(status, text[:200])
        return self._parse(text)

    @staticmethod
    def _parse(text: str) -> dict:
        try:
            body = json.loads(text)
        except ValueError:
            raise PermanentContextError(200, "corpo não é JSON") from None
        if (not isinstance(body, dict) or not isinstance(body.get("conversation"), dict)
                or not isinstance(body.get("messages"), list)):
            raise PermanentContextError(200, "corpo fora do schema context")
        return body
