import hashlib
import hmac
import json

import aiohttp
import pytest
from aiohttp import web

from channel_simulator import whatsapp
from channel_simulator.records import JsonlWriter, read_jsonl

SECRET = "whatsapp-app-secret-de-teste"
TOKEN = "whatsapp-access-token-de-teste"


def payload(**overrides):
    arguments = {
        "phone_number_id": "110000000000001",
        "display_phone_number": "551140000001",
        "contact_name": "Ana Lima",
        "wa_id": "+5511912345678",
        "message_id": "wamid.abc",
        "text": "Meu repasse não caiu",
        "timestamp": 1794578531,
    }
    return whatsapp.build_payload(**{**arguments, **overrides})


def test_payload_de_texto_no_formato_lido_pelo_core():
    data = payload()

    assert data["object"] == "whatsapp_business_account"
    change = data["entry"][0]["changes"][0]
    assert change["field"] == "messages"
    value = change["value"]
    assert value["messaging_product"] == "whatsapp"
    assert value["metadata"] == {"display_phone_number": "551140000001", "phone_number_id": "110000000000001"}
    assert value["contacts"] == [{"profile": {"name": "Ana Lima"}, "wa_id": "5511912345678"}]
    assert value["messages"] == [
        {
            "from": "5511912345678",
            "id": "wamid.abc",
            "timestamp": "1794578531",
            "type": "text",
            "text": {"body": "Meu repasse não caiu"},
        }
    ]


def test_payload_de_imagem_com_legenda():
    attachment = {"kind": "image", "filename": "comprovante.jpg", "content_type": "image/jpeg", "size": 10}

    message = payload(attachment=attachment)["entry"][0]["changes"][0]["value"]["messages"][0]

    assert message["type"] == "image"
    assert message["image"] == {"mime_type": "image/jpeg", "caption": "Meu repasse não caiu"}
    assert "text" not in message


def test_payload_de_documento_com_nome_do_arquivo():
    attachment = {"kind": "document", "filename": "extrato.pdf", "content_type": "application/pdf", "size": 10}

    message = payload(attachment=attachment)["entry"][0]["changes"][0]["value"]["messages"][0]

    assert message["type"] == "document"
    assert message["document"] == {
        "mime_type": "application/pdf",
        "caption": "Meu repasse não caiu",
        "filename": "extrato.pdf",
    }


def test_id_da_mensagem():
    assert whatsapp.new_message_id().startswith("wamid.")
    assert whatsapp.new_message_id() != whatsapp.new_message_id()


def test_assinatura_x_hub_signature_256():
    body = whatsapp.serialize(payload())
    expected = hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()

    assert whatsapp.sign(SECRET, body) == f"sha256={expected}"


async def test_envia_ao_core_com_o_corpo_assinado(aiohttp_server):
    seen = {}

    async def webhook(request):
        seen["body"] = await request.read()
        seen["signature"] = request.headers.get("X-Hub-Signature-256")
        return web.Response(status=200)

    app = web.Application()
    app.router.add_post("/channels/whatsapp/webhook", webhook)
    server = await aiohttp_server(app)

    async with aiohttp.ClientSession() as session:
        status = await whatsapp.send(session, str(server.make_url("")).rstrip("/"), SECRET, payload())

    assert status == 200
    assert json.loads(seen["body"]) == payload()
    expected = hmac.new(SECRET.encode(), seen["body"], hashlib.sha256).hexdigest()
    assert seen["signature"] == f"sha256={expected}"


async def fake_verification_server(aiohttp_server, echo: bool):
    async def verification(request):
        if request.query.get("hub.mode") != "subscribe" or request.query.get("hub.verify_token") != "certo":
            return web.Response(status=403)
        return web.Response(text=request.query["hub.challenge"] if echo else "outro", content_type="text/plain")

    app = web.Application()
    app.router.add_get("/channels/whatsapp/webhook", verification)
    return await aiohttp_server(app)


async def test_verificacao_com_resposta_certa(aiohttp_server):
    server = await fake_verification_server(aiohttp_server, echo=True)

    async with aiohttp.ClientSession() as session:
        ok, status, _ = await whatsapp.verify(session, str(server.make_url("")).rstrip("/"), "certo")

    assert (ok, status) == (True, 200)


async def test_verificacao_com_token_errado(aiohttp_server):
    server = await fake_verification_server(aiohttp_server, echo=True)

    async with aiohttp.ClientSession() as session:
        ok, status, _ = await whatsapp.verify(session, str(server.make_url("")).rstrip("/"), "errado")

    assert (ok, status) == (False, 403)


async def test_verificacao_com_challenge_diferente(aiohttp_server):
    server = await fake_verification_server(aiohttp_server, echo=False)

    async with aiohttp.ClientSession() as session:
        ok, status, _ = await whatsapp.verify(session, str(server.make_url("")).rstrip("/"), "certo")

    assert (ok, status) == (False, 200)


@pytest.fixture
async def receiver(aiohttp_client, tmp_path):
    writer = JsonlWriter(tmp_path / "received.jsonl")
    app = web.Application()
    app.router.add_post("/{version}/{phone_number_id}/messages", whatsapp.receiver(TOKEN, writer))
    yield await aiohttp_client(app), tmp_path / "received.jsonl"
    writer.close()


OUTBOUND = {
    "messaging_product": "whatsapp",
    "recipient_type": "individual",
    "to": "5511912345678",
    "type": "text",
    "text": {"body": "Seu repasse cai amanhã."},
}


async def test_receptor_grava_a_resposta_e_responde_no_formato_da_meta(receiver):
    client, path = receiver

    response = await client.post(
        "/v21.0/110000000000001/messages",
        json=OUTBOUND,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "X-Cloudesk-Message-Id": "0199-core",
            "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        },
    )

    assert response.status == 200
    data = await response.json()
    assert data["messaging_product"] == "whatsapp"
    assert data["contacts"] == [{"input": "5511912345678", "wa_id": "5511912345678"}]
    assert data["messages"][0]["id"].startswith("wamid.")
    [record] = read_jsonl(path)
    assert record["channel"] == "whatsapp"
    assert record["core_message_id"] == "0199-core"
    assert record["recipient"] == "5511912345678"
    assert record["sender"] == "110000000000001"
    assert record["text"] == "Seu repasse cai amanhã."
    assert record["traceparent"] == "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    assert record["received_at"].endswith("Z")


async def test_receptor_aceita_qualquer_segmento_de_versao(receiver):
    client, path = receiver

    response = await client.post(
        "/v1/120000000000001/messages", json=OUTBOUND, headers={"Authorization": f"Bearer {TOKEN}"}
    )

    assert response.status == 200
    assert read_jsonl(path)[0]["sender"] == "120000000000001"


async def test_receptor_recusa_bearer_errado_ou_ausente(receiver):
    client, path = receiver

    wrong = await client.post("/v1/110000000000001/messages", json=OUTBOUND, headers={"Authorization": "Bearer x"})
    missing = await client.post("/v1/110000000000001/messages", json=OUTBOUND)

    assert wrong.status == 401
    assert missing.status == 401
    assert read_jsonl(path) == []


async def test_receptor_recusa_corpo_invalido(receiver):
    client, path = receiver
    headers = {"Authorization": f"Bearer {TOKEN}"}

    for body in (
        {**OUTBOUND, "messaging_product": "outro"},
        {key: value for key, value in OUTBOUND.items() if key != "to"},
        {**OUTBOUND, "text": {}},
    ):
        response = await client.post("/v1/110000000000001/messages", json=body, headers=headers)
        assert response.status == 400
        assert "message" in (await response.json())["error"]

    not_json = await client.post("/v1/110000000000001/messages", data=b"{", headers=headers)
    assert not_json.status == 400
    assert read_jsonl(path) == []
