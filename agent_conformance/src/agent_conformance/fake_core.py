"""Core falso do kit: responde ao GET da context_url do agente sob teste.

Rota: GET /api/v1/agent/brands/<brand>/conversations/<conversation_id>/context.

Cada teste programa as respostas da sua conversa (program): uma resposta ou uma sequência delas,
consumidas em ordem; a última se repete. Uma resposta é o corpo do contexto (status 200) ou um par
(status, corpo). Antes de responder, o Core falso confere a assinatura do contrato com o segredo
do kit, a marca do caminho contra a marca do contexto programado e o header traceparent. Toda
requisição fica registrada (requests_for), com o resultado de cada conferência.

| Situação | Resposta |
| - | - |
| assinatura ausente, inválida ou fora da janela | 401 invalid_signature |
| conversa sem resposta programada | 404 not_found |
| marca do caminho diferente da marca do contexto | 404 not_found |
| conversa programada | a próxima resposta programada |
"""

import asyncio
from dataclasses import dataclass, field

from aiohttp import web

from agent_conformance import signature

ROUTE = "/api/v1/agent/brands/{brand}/conversations/{conversation_id}/context"


@dataclass
class ContextRequest:
    brand: str
    conversation_id: str
    path: str
    headers: dict
    signature_problem: str | None
    status: int


@dataclass
class _Program:
    brand: str
    responses: list = field(default_factory=list)


class FakeCore:
    def __init__(self, secret: str, port: int, host: str = "0.0.0.0"):
        self.secret = secret
        self.port = port
        self.host = host
        self.requests: list[ContextRequest] = []
        self._programs: dict[str, _Program] = {}
        self._changed = asyncio.Condition()
        self._runner: web.AppRunner | None = None

    def program(self, conversation_id: str, brand: str, *responses) -> None:
        """Respostas do contexto da conversa, em ordem; a última se repete."""
        if not responses:
            raise ValueError("informe ao menos uma resposta")
        self._programs[conversation_id] = _Program(brand, list(responses))

    def requests_for(self, conversation_id: str) -> list[ContextRequest]:
        return [item for item in self.requests if item.conversation_id == conversation_id]

    async def wait_requests(self, conversation_id: str, count: int, timeout: float) -> list[ContextRequest]:
        """Espera count leituras do contexto da conversa; devolve as leituras até o fim da espera."""
        async def enough():
            async with self._changed:
                await self._changed.wait_for(lambda: len(self.requests_for(conversation_id)) >= count)

        try:
            await asyncio.wait_for(enough(), timeout)
        except TimeoutError:
            pass
        return self.requests_for(conversation_id)

    async def start(self) -> None:
        app = web.Application()
        app.router.add_get(ROUTE, self._handle)
        self._runner = web.AppRunner(app)
        await self._runner.setup()
        await web.TCPSite(self._runner, self.host, self.port).start()

    async def stop(self) -> None:
        if self._runner is not None:
            await self._runner.cleanup()

    async def _handle(self, request: web.Request) -> web.Response:
        brand = request.match_info["brand"]
        conversation_id = request.match_info["conversation_id"]
        path = request.path_qs
        problem = signature.problem(self.secret, request.headers, "GET", path, "")
        program = self._programs.get(conversation_id)

        if problem is not None:
            status, body = 401, {"error": "invalid_signature"}
        elif program is None or program.brand != brand:
            status, body = 404, {"error": "not_found"}
        else:
            answer = program.responses.pop(0) if len(program.responses) > 1 else program.responses[0]
            status, body = answer if isinstance(answer, tuple) else (200, answer)

        await self._record(ContextRequest(brand, conversation_id, path, dict(request.headers), problem, status))
        return web.json_response(body, status=status)

    async def _record(self, item: ContextRequest) -> None:
        async with self._changed:
            self.requests.append(item)
            self._changed.notify_all()
