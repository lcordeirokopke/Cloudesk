"""Comando send e cenário entre canais contra um Core falso, o receptor de streams do próprio
simulador e um SMTP falso."""

import json
import random
from dataclasses import replace

import pytest
from aiohttp import web

from channel_simulator import personas, sender, signature, whatsapp
from channel_simulator.records import read_jsonl
from channel_simulator.server import create_app


class FakeCore:
    def __init__(self, secret_whatsapp: str, secret_chat: str):
        self.secret_whatsapp = secret_whatsapp
        self.secret_chat = secret_chat
        self.whatsapp = []
        self.chat = []
        self.app = web.Application()
        self.app.router.add_post("/channels/whatsapp/webhook", self.whatsapp_webhook)
        self.app.router.add_post("/channels/chat/messages", self.chat_messages)

    async def whatsapp_webhook(self, request):
        body = await request.read()
        if request.headers.get("X-Hub-Signature-256") != whatsapp.sign(self.secret_whatsapp, body):
            return web.Response(status=401)
        self.whatsapp.append(json.loads(body))
        return web.Response(status=200)

    async def chat_messages(self, request):
        body = await request.text()
        timestamp = request.headers["X-Cloudesk-Timestamp"]
        expected = signature.sign(self.secret_chat, timestamp, "POST", "/channels/chat/messages", body)
        if request.headers["X-Cloudesk-Signature"] != expected:
            return web.Response(status=401)
        data = json.loads(body)
        self.chat.append(data)
        return web.json_response(
            {"conversation_id": "conv-1", "sequence": len(self.chat), "stream": f"stream-{data['app_user_id']}"}
        )


@pytest.fixture
async def environment(aiohttp_server, settings, smtp_server):
    core = FakeCore(settings.whatsapp_app_secret, settings.chat_signing_secret)
    core_server = await aiohttp_server(core.app)
    simulator_server = await aiohttp_server(create_app(settings, background=False))
    host, port = smtp_server.server_address
    configured = replace(
        settings,
        core_url=str(core_server.make_url("")).rstrip("/"),
        smtp_host=host,
        smtp_port=port,
        port=simulator_server.port,
    )
    return configured, core, smtp_server


def test_mesma_semente_sorteia_as_mesmas_mensagens(personas_path):
    loaded = personas.load(personas_path)
    options = sender.SendOptions(count=10, seed=5, attachments=0.5)

    def sample(seed):
        rng = random.Random(seed)
        return [sender.plan(loaded, options, rng) for _ in range(10)]

    assert sample(5) == sample(5)
    assert {item.channel for item in sample(5)} <= {"whatsapp", "chat", "email"}


def test_marca_e_canal_fixos(personas_path):
    loaded = personas.load(personas_path)
    options = sender.SendOptions(channel="chat", brand="jim", contacts="new")
    rng = random.Random(1)

    items = [sender.plan(loaded, options, rng) for _ in range(5)]

    assert {item.brand.slug for item in items} == {"jim"}
    assert {item.channel for item in items} == {"chat"}
    assert all(item.contact.origin == "new" and item.contact.whatsapp.startswith("+1") for item in items)


async def test_send_envia_nos_tres_canais_e_grava_sent_jsonl(environment):
    settings, core, smtp = environment
    options = sender.SendOptions(count=12, rate=200, seed=3, attachments=0.5)

    summary = await sender.run_send(settings, personas.load(settings.personas_path), options, run_id="run-teste")

    records = read_jsonl(settings.data_dir / "runs" / "run-teste" / "sent.jsonl")
    assert summary["sent"] == 12
    assert len(records) == 12
    by_channel = {channel: [r for r in records if r["channel"] == channel] for channel in ("whatsapp", "chat", "email")}
    assert len(core.whatsapp) == len(by_channel["whatsapp"])
    assert len(core.chat) == len(by_channel["chat"])
    assert len(smtp.messages) == len(by_channel["email"])
    assert all(record["status"] in (200, 250) for record in records)
    assert len({record["external_id"] for record in records}) == 12
    for record in records:
        assert record["run_id"] == "run-teste"
        assert record["contacts"] == "seed"
        assert record["intent"]
        assert record["duration_ms"] >= 0
    for record in by_channel["whatsapp"]:
        assert record["external_id"].startswith("wamid.")
        assert record["identity"].startswith("+")
    for record in by_channel["email"]:
        assert record["status"] == 250
        assert record["external_id"].endswith("@simulator.cloudesk.test")
    for record in by_channel["chat"]:
        assert record["conversation_id"] == "conv-1"
        assert record["stream_status"] == 200
        assert record["identity"].startswith("app-")

    streams = read_jsonl(settings.data_dir / "streams.jsonl")
    assert {(item["stream"], item["app_user_id"]) for item in streams} == {
        (f"stream-{record['identity']}", record["identity"]) for record in by_channel["chat"]
    }


async def test_cenario_entre_canais(environment):
    settings, core, smtp = environment

    result = await sender.run_cross_channel(settings, personas.load(settings.personas_path), "infinitepay", seed=2)

    records = read_jsonl(settings.data_dir / "runs" / result["run_id"] / "sent.jsonl")
    assert [record["channel"] for record in records] == ["whatsapp", "chat", "email"]
    assert result["conversation_id"] == "conv-1"
    contact = next(c for c in personas.load(settings.personas_path).brand("infinitepay").contacts if c.name == result["contact"])
    assert [record["identity"] for record in records] == [contact.whatsapp, contact.chat, contact.email]
    assert core.whatsapp[0]["entry"][0]["changes"][0]["value"]["messages"][0]["from"] == contact.whatsapp[1:]
    assert len(smtp.messages) == 1


async def test_core_fora_do_ar_registra_o_erro(settings, unused_tcp_port):
    offline = replace(settings, core_url=f"http://127.0.0.1:{unused_tcp_port}")
    options = sender.SendOptions(channel="whatsapp", count=1, rate=10)

    summary = await sender.run_send(offline, personas.load(settings.personas_path), options, run_id="run-off")

    [record] = read_jsonl(settings.data_dir / "runs" / "run-off" / "sent.jsonl")
    assert record["status"] == "ClientConnectorError"
    assert record["error"]
    assert summary["status"] == {"whatsapp:ClientConnectorError": 1}


async def test_erro_na_montagem_vira_registro_e_o_comando_segue(environment):
    settings, core, smtp = environment
    loaded = personas.load(settings.personas_path)
    brand = loaded.brand("infinitepay")
    broken = replace(brand.contacts[0], email="bárbara@example.com")
    loaded = replace(loaded, brands=(replace(brand, contacts=(broken,)),))
    options = sender.SendOptions(channel="email", brand="infinitepay", count=2, rate=100)

    summary = await sender.run_send(settings, loaded, options, run_id="run-erro")

    records = read_jsonl(settings.data_dir / "runs" / "run-erro" / "sent.jsonl")
    assert [record["status"] for record in records] == ["UnicodeEncodeError", "UnicodeEncodeError"]
    assert all(record["error"] and record["external_id"] for record in records)
    assert summary["sent"] == 2
    assert smtp.messages == []


def test_id_da_execucao():
    run_id = sender.new_run_id()

    assert run_id[8] == "T" and run_id[15] == "Z" and run_id[16] == "-"
    assert len(run_id.split("-")[1]) == 4
