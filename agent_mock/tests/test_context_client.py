import json

import aiohttp
import pytest
from aiohttp import web
from conftest import CONVERSATION_ID, context_for, event_body, read_json, record, CONTRACTS

from agent_mock import events, signature
from agent_mock.config import Settings
from agent_mock.context_client import ContextClient, PermanentContextError, backoff_delays

SECRET = "segredo-do-contexto"
TRACEPARENT = "00-4bf92f3577b34da6a3ce929d0e0e4736-1111111111111111-01"
BODY = event_body()
CONTEXT = context_for(BODY)


class Core:
    """Servidor de teste no papel do Core: confere a assinatura e responde em sequência."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    async def handle(self, request: web.Request):
        timestamp = request.headers.get(signature.TIMESTAMP_HEADER, "")
        expected = signature.sign(SECRET, timestamp, request.method, request.path_qs, "")
        self.requests.append({
            "path": request.path_qs,
            "signed": request.headers.get(signature.SIGNATURE_HEADER) == expected,
            "traceparent": request.headers.get("traceparent"),
        })
        status, body = self.responses.pop(0) if len(self.responses) > 1 else self.responses[0]
        return web.Response(status=status, text=body if isinstance(body, str) else json.dumps(body),
                            content_type="application/json")


@pytest.fixture
async def serve():
    runners = []

    async def start(responses):
        core = Core(responses)
        app = web.Application()
        app.router.add_get("/api/v1/agent/brands/{brand}/conversations/{id}/context", core.handle)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        runners.append(runner)
        port = site._server.sockets[0].getsockname()[1]
        return core, f"http://127.0.0.1:{port}"

    yield start
    for runner in runners:
        await runner.cleanup()


async def client_for(url, sleeps):
    session = aiohttp.ClientSession()

    async def sleep(delay):
        sleeps.append(delay)

    settings = Settings(core_url=url, context_secret=SECRET, context_timeout_seconds=2)
    return session, ContextClient(session, settings, sleep=sleep)


async def test_get_assinado_com_a_marca_no_caminho_e_traceparent(serve):
    core, url = await serve([(200, CONTEXT)])
    session, client = await client_for(url, [])
    try:
        context = await client.fetch(events.parse(record(BODY)), TRACEPARENT)
    finally:
        await session.close()

    assert context == CONTEXT
    assert core.requests == [{
        "path": f"/api/v1/agent/brands/infinitepay/conversations/{CONVERSATION_ID}/context",
        "signed": True,
        "traceparent": TRACEPARENT,
    }]


def test_contexto_de_exemplo_do_contrato_e_aceito():
    for path in (CONTRACTS / "examples" / "context" / "valid").glob("*.json"):
        assert ContextClient._parse(json.dumps(read_json(path))) == read_json(path)


@pytest.mark.parametrize("status", [401, 404, 422, 400, 403])
async def test_erro_permanente(serve, status):
    core, url = await serve([(status, {"status": "error", "error": "x", "message": "y"})])
    sleeps = []
    session, client = await client_for(url, sleeps)
    try:
        with pytest.raises(PermanentContextError) as failure:
            await client.fetch(events.parse(record(BODY)), TRACEPARENT)
    finally:
        await session.close()

    assert failure.value.status == status
    assert sleeps == []
    assert len(core.requests) == 1


async def test_corpo_fora_do_formato_e_permanente(serve):
    _core, url = await serve([(200, "não é json")])
    session, client = await client_for(url, [])
    try:
        with pytest.raises(PermanentContextError):
            await client.fetch(events.parse(record(BODY)), TRACEPARENT)
    finally:
        await session.close()


@pytest.mark.parametrize("status", [408, 429, 500, 502, 503])
async def test_erro_transitorio_repete_ate_o_sucesso(serve, status):
    core, url = await serve([(status, "{}"), (status, "{}"), (200, CONTEXT)])
    sleeps = []
    session, client = await client_for(url, sleeps)
    try:
        context = await client.fetch(events.parse(record(BODY)), TRACEPARENT)
    finally:
        await session.close()

    assert context == CONTEXT
    assert sleeps == [2.0, 4.0]
    assert len(core.requests) == 3


async def test_erro_de_rede_e_transitorio():
    sleeps = []
    session, client = await client_for("http://127.0.0.1:9", sleeps)
    calls = []

    async def sleep(delay):
        sleeps.append(delay)
        if len(sleeps) == 3:
            raise RuntimeError("parar")

    client.sleep = sleep
    try:
        with pytest.raises(RuntimeError):
            await client.fetch(events.parse(record(BODY)), TRACEPARENT, on_retry=lambda *args: calls.append(args))
    finally:
        await session.close()

    assert sleeps == [2.0, 4.0, 8.0]
    assert len(calls) == 3


def test_pausas_exponenciais_ate_60_segundos():
    delays = backoff_delays()

    assert [next(delays) for _ in range(8)] == [2.0, 4.0, 8.0, 16.0, 32.0, 60.0, 60.0, 60.0]
