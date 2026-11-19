import asyncio
import json

import aiohttp
import pytest
from aiohttp import web

from channel_simulator import chat, signature
from channel_simulator.records import JsonlWriter, read_jsonl

SECRET = "chat-signing-secret-de-teste"

# HTML do partial channels/chat/_message.html.erb dentro do Turbo Stream de broadcast_append_to.
TURBO_STREAM = (
    '<turbo-stream action="append" target="messages"><template>'
    '<div id="message_0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b" class="chat-message chat-message-ai"'
    ' data-sequence="4" data-channel="chat">\n'
    '  <span class="chat-message__meta">ai · chat</span>\n'
    '  <p class="chat-message__body">Seu repasse cai amanhã &amp; o comprovante chega por e-mail. '
    "D&#39;accord?</p>\n"
    "</div></template></turbo-stream>"
)


def turbo_stream(author: str, message_id: str = "0199-core", sequence: int = 4) -> str:
    return TURBO_STREAM.replace("chat-message-ai", f"chat-message-{author}").replace(
        "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", message_id
    ).replace('data-sequence="4"', f'data-sequence="{sequence}"')


# Envio


def test_corpo_do_envio():
    body = chat.build_body("infinitepay", "app-ana", "id-1", "Oi", [{"kind": "image", "filename": "a.jpg"}])

    assert json.loads(body) == {
        "brand": "infinitepay",
        "app_user_id": "app-ana",
        "client_message_id": "id-1",
        "text": "Oi",
        "attachments": [{"kind": "image", "filename": "a.jpg"}],
    }


async def test_envio_assinado_com_a_assinatura_do_contrato(aiohttp_server):
    seen = {}

    async def messages(request):
        seen["body"] = await request.text()
        seen["headers"] = dict(request.headers)
        return web.json_response({"conversation_id": "c-1", "sequence": 3, "stream": "assinado"})

    app = web.Application()
    app.router.add_post("/channels/chat/messages", messages)
    server = await aiohttp_server(app)
    body = chat.build_body("infinitepay", "app-ana", "id-1", "Oi", [])

    async with aiohttp.ClientSession() as session:
        status, data = await chat.send(session, str(server.make_url("")).rstrip("/"), SECRET, body)

    assert status == 200
    assert data == {"conversation_id": "c-1", "sequence": 3, "stream": "assinado"}
    assert seen["body"] == body
    timestamp = seen["headers"]["X-Cloudesk-Timestamp"]
    assert seen["headers"]["X-Cloudesk-Signature"] == signature.sign(
        SECRET, timestamp, "POST", "/channels/chat/messages", body
    )


# Registro de streams


@pytest.fixture
async def streams(aiohttp_client, tmp_path):
    registry = chat.StreamRegistry(tmp_path / "streams.jsonl")
    app = web.Application()
    app.router.add_post("/chat/streams", chat.streams_handler(registry))
    yield await aiohttp_client(app), registry
    registry.close()


async def test_registro_de_stream_idempotente(streams, tmp_path):
    client, registry = streams

    first = await client.post("/chat/streams", json={"stream": "s-1", "app_user_id": "app-ana"})
    again = await client.post("/chat/streams", json={"stream": "s-1", "app_user_id": "app-ana"})

    assert first.status == 200
    assert (await first.json())["result"] == "created"
    assert again.status == 200
    assert (await again.json())["result"] == "exists"
    assert registry.streams() == ["s-1"]
    assert [record["stream"] for record in read_jsonl(tmp_path / "streams.jsonl")] == ["s-1"]


async def test_registro_sem_stream_ou_sem_app_user_id(streams, tmp_path):
    client, registry = streams

    for body in ({"stream": "s-1"}, {"app_user_id": "app-ana"}, {"stream": "", "app_user_id": "app-ana"}, []):
        response = await client.post("/chat/streams", json=body)
        assert response.status == 400

    not_json = await client.post("/chat/streams", data=b"{")
    assert not_json.status == 400
    assert registry.streams() == []


async def test_stream_registrado_com_outro_app_user_id_recebe_409_e_mantem_o_par(streams, tmp_path):
    client, registry = streams
    await client.post("/chat/streams", json={"stream": "s-1", "app_user_id": "app-ana"})

    response = await client.post("/chat/streams", json={"stream": "s-1", "app_user_id": "app-bruno"})

    assert response.status == 409
    assert (await response.json())["app_user_id"] == "app-ana"
    assert registry.app_user_id("s-1") == "app-ana"
    assert len(read_jsonl(tmp_path / "streams.jsonl")) == 1


def test_registro_persistido_e_relido(tmp_path):
    path = tmp_path / "streams.jsonl"
    registry = chat.StreamRegistry(path)
    registry.register("s-1", "app-ana")
    registry.register("s-2", "app-bruno")
    registry.close()

    reloaded = chat.StreamRegistry(path)

    assert reloaded.streams() == ["s-1", "s-2"]
    assert reloaded.app_user_id("s-2") == "app-bruno"
    assert reloaded.register("s-1", "app-ana") == "exists"
    reloaded.close()


def test_listener_recebe_so_streams_novos(tmp_path):
    registry = chat.StreamRegistry(tmp_path / "streams.jsonl")
    seen = []
    registry.add_listener(seen.append)

    registry.register("s-1", "app-ana")
    registry.register("s-1", "app-ana")
    registry.register("s-1", "app-bruno")

    assert seen == ["s-1"]
    registry.close()


# Parser


def test_parser_le_o_partial_da_mensagem():
    assert chat.parse_turbo_stream(TURBO_STREAM) == {
        "core_message_id": "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
        "sequence": 4,
        "channel": "chat",
        "author": "ai",
        "text": "Seu repasse cai amanhã & o comprovante chega por e-mail. D'accord?",
    }


def test_parser_sem_mensagem():
    assert chat.parse_turbo_stream('<turbo-stream action="remove" target="x"></turbo-stream>') is None


# Cliente Action Cable


class FakeCable:
    """Servidor Action Cable falso. Na primeira conexão, depois de confirmar a assinatura, envia uma
    mensagem do lojista, uma da IA e fecha; nas seguintes, envia uma mensagem do analista."""

    def __init__(self):
        self.connections = []
        self.app = web.Application()
        self.app.router.add_get("/cable", self.handle)

    async def handle(self, request):
        ws = web.WebSocketResponse(protocols=("actioncable-v1-json",))
        await ws.prepare(request)
        connection = {"origin": request.headers.get("Origin"), "protocol": ws.ws_protocol, "subscribed": []}
        self.connections.append(connection)
        number = len(self.connections)
        await ws.send_json({"type": "welcome"})
        await ws.send_json({"type": "ping", "message": 1})

        async for frame in ws:
            command = json.loads(frame.data)
            if command["command"] != "subscribe":
                continue
            identifier = command["identifier"]
            stream = json.loads(identifier)["signed_stream_name"]
            connection["subscribed"].append(stream)
            if stream == "recusado":
                await ws.send_json({"type": "reject_subscription", "identifier": identifier})
                continue
            await ws.send_json({"type": "confirm_subscription", "identifier": identifier})
            if number == 1:
                await ws.send_json({"identifier": identifier, "message": turbo_stream("customer", "m-1", 3)})
                await ws.send_json({"identifier": identifier, "message": turbo_stream("ai", "m-2", 4)})
                await ws.close()
                break
            await ws.send_json({"identifier": identifier, "message": turbo_stream("analyst", f"m-{stream}", 5)})
        return ws


async def wait_for(condition, timeout=5.0):
    async def poll():
        while not condition():
            await asyncio.sleep(0.02)

    await asyncio.wait_for(poll(), timeout)


async def test_cliente_assina_grava_respostas_e_reconecta(aiohttp_server, tmp_path):
    fake = FakeCable()
    server = await aiohttp_server(fake.app)
    registry = chat.StreamRegistry(tmp_path / "streams.jsonl")
    registry.register("s-1", "app-ana")
    received_path = tmp_path / "received.jsonl"
    received = JsonlWriter(received_path)
    client = chat.CableClient(
        str(server.make_url("/cable")).replace("http", "ws"), "http://web:3000", registry, received,
        initial_backoff=0.05,
    )
    task = asyncio.create_task(client.run())

    try:
        # Primeira conexão: grava só a resposta da IA; o servidor fecha e o cliente reconecta.
        await wait_for(lambda: len(fake.connections) >= 2 and client.connected.is_set())
        # Stream novo registrado com a conexão aberta: assinado na hora.
        registry.register("s-2", "app-bruno")
        await wait_for(lambda: len(read_jsonl(received_path)) >= 3)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        received.close()
        registry.close()

    first, second = fake.connections[:2]
    assert first["origin"] == "http://web:3000"
    assert first["protocol"] == "actioncable-v1-json"
    assert first["subscribed"] == ["s-1"]
    assert second["subscribed"] == ["s-1", "s-2"]

    records = read_jsonl(received_path)
    assert [record["core_message_id"] for record in records] == ["m-2", "m-s-1", "m-s-2"]
    assert records[0] == {
        "channel": "chat",
        "core_message_id": "m-2",
        "recipient": "app-ana",
        "stream": "s-1",
        "sender": None,
        "author": "ai",
        "text": "Seu repasse cai amanhã & o comprovante chega por e-mail. D'accord?",
        "received_at": records[0]["received_at"],
        "sequence": 4,
    }
    assert records[2]["recipient"] == "app-bruno"
    assert records[2]["author"] == "analyst"


class SilentCable:
    """Servidor que aceita o WebSocket e, conforme o modo, não manda welcome ou manda só o welcome."""

    def __init__(self, welcome: bool):
        self.welcome = welcome
        self.connections = 0
        self.subscriptions = 0
        self.app = web.Application()
        self.app.router.add_get("/cable", self.handle)

    async def handle(self, request):
        ws = web.WebSocketResponse(protocols=("actioncable-v1-json",))
        await ws.prepare(request)
        self.connections += 1
        if self.welcome:
            await ws.send_json({"type": "welcome"})
        async for frame in ws:
            if json.loads(frame.data).get("command") == "subscribe":
                self.subscriptions += 1
        return ws


async def run_against_silent_cable(aiohttp_server, tmp_path, welcome: bool):
    fake = SilentCable(welcome)
    server = await aiohttp_server(fake.app)
    registry = chat.StreamRegistry(tmp_path / "streams.jsonl")
    registry.register("s-1", "app-ana")
    received = JsonlWriter(tmp_path / "received.jsonl")
    client = chat.CableClient(
        str(server.make_url("/cable")).replace("http", "ws"), "http://web:3000", registry, received,
        initial_backoff=0.01, stale_threshold=0.2,
    )
    task = asyncio.create_task(client.run())
    try:
        await wait_for(lambda: fake.connections >= 3)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        received.close()
        registry.close()
    return fake


async def test_cliente_reconecta_quando_o_welcome_nao_chega(aiohttp_server, tmp_path):
    fake = await run_against_silent_cable(aiohttp_server, tmp_path, welcome=False)

    assert fake.connections >= 3
    assert fake.subscriptions == 0


async def test_cliente_reconecta_e_reassina_quando_os_pings_param(aiohttp_server, tmp_path):
    fake = await run_against_silent_cable(aiohttp_server, tmp_path, welcome=True)

    assert fake.connections >= 3
    assert fake.subscriptions >= 2


async def test_cliente_ignora_assinatura_recusada(aiohttp_server, tmp_path):
    fake = FakeCable()
    server = await aiohttp_server(fake.app)
    registry = chat.StreamRegistry(tmp_path / "streams.jsonl")
    registry.register("recusado", "app-x")
    received = JsonlWriter(tmp_path / "received.jsonl")
    client = chat.CableClient(str(server.make_url("/cable")).replace("http", "ws"), "http://web:3000", registry, received)
    task = asyncio.create_task(client.run())

    try:
        await wait_for(lambda: fake.connections and fake.connections[0]["subscribed"] == ["recusado"])
        await asyncio.sleep(0.1)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        received.close()
        registry.close()

    assert len(fake.connections) == 1
    assert read_jsonl(tmp_path / "received.jsonl") == []
