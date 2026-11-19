"""WhatsApp: o simulador faz o papel da Meta (Cloud API) e do lojista.

Envio: webhook da Cloud API, uma mensagem por POST, em {CORE_URL}/channels/whatsapp/webhook,
assinado com X-Hub-Signature-256 (sha256= seguido do HMAC-SHA256 hexadecimal do corpo, com
WHATSAPP_APP_SECRET). O id da mensagem é wamid.<uuid>.

Verificação: GET do webhook com hub.mode, hub.verify_token e hub.challenge; sucesso quando o Core
responde 200 com o próprio challenge.

Receptor: POST /{versão}/{phone_number_id}/messages, o envio da Cloud API que o Core faz para
entregar a resposta. Confere o Bearer com WHATSAPP_ACCESS_TOKEN e grava a resposta no registro.
"""

import hashlib
import hmac
import json
import secrets
import time
import uuid

import aiohttp
from aiohttp import web

from .records import JsonlWriter, utc_now

WEBHOOK_PATH = "/channels/whatsapp/webhook"
SIGNATURE_HEADER = "X-Hub-Signature-256"
CORE_MESSAGE_ID_HEADER = "X-Cloudesk-Message-Id"

# Id da conta do WhatsApp Business no payload; o Core não lê esse campo.
WABA_ID = "100000000000000"


def new_message_id() -> str:
    return f"wamid.{uuid.uuid4()}"


def build_payload(
    *,
    phone_number_id: str,
    display_phone_number: str,
    contact_name: str,
    wa_id: str,
    message_id: str,
    text: str,
    attachment: dict | None = None,
    timestamp: int | None = None,
) -> dict:
    """Webhook da Cloud API com uma mensagem do lojista.

    wa_id é o telefone do lojista sem o +. attachment traz kind (image ou document), content_type
    e filename; o texto vai na legenda.
    """
    wa_id = wa_id.removeprefix("+")
    message = {
        "from": wa_id,
        "id": message_id,
        "timestamp": str(int(time.time() if timestamp is None else timestamp)),
    }
    if attachment is None:
        message["type"] = "text"
        message["text"] = {"body": text}
    else:
        kind = attachment["kind"]
        media = {"mime_type": attachment["content_type"], "caption": text}
        if kind == "document":
            media["filename"] = attachment["filename"]
        message["type"] = kind
        message[kind] = media

    return {
        "object": "whatsapp_business_account",
        "entry": [
            {
                "id": WABA_ID,
                "changes": [
                    {
                        "field": "messages",
                        "value": {
                            "messaging_product": "whatsapp",
                            "metadata": {
                                "display_phone_number": display_phone_number,
                                "phone_number_id": phone_number_id,
                            },
                            "contacts": [{"profile": {"name": contact_name}, "wa_id": wa_id}],
                            "messages": [message],
                        },
                    }
                ],
            }
        ],
    }


def serialize(payload: dict) -> bytes:
    """Corpo serializado uma vez: a assinatura é calculada sobre estes bytes."""
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def sign(secret: str, body: bytes) -> str:
    if not secret:
        raise ValueError("WHATSAPP_APP_SECRET não informado")
    return "sha256=" + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()


async def send(session: aiohttp.ClientSession, core_url: str, app_secret: str, payload: dict) -> int:
    """Envia o webhook ao Core e devolve o status HTTP."""
    body = serialize(payload)
    headers = {"Content-Type": "application/json", SIGNATURE_HEADER: sign(app_secret, body)}
    async with session.post(f"{core_url}{WEBHOOK_PATH}", data=body, headers=headers) as response:
        await response.read()
        return response.status


async def verify(session: aiohttp.ClientSession, core_url: str, verify_token: str) -> tuple[bool, int, str]:
    """Handshake de verificação do webhook. Devolve (sucesso, status, corpo)."""
    challenge = secrets.token_hex(8)
    params = {"hub.mode": "subscribe", "hub.verify_token": verify_token, "hub.challenge": challenge}
    async with session.get(f"{core_url}{WEBHOOK_PATH}", params=params) as response:
        body = await response.text()
        return response.status == 200 and body == challenge, response.status, body


def _error(status: int, message: str) -> web.Response:
    return web.json_response({"error": {"message": message}}, status=status)


def receiver(access_token: str, received: JsonlWriter):
    """Handler de POST /{versão}/{phone_number_id}/messages."""

    async def handle(request: web.Request) -> web.Response:
        expected = f"Bearer {access_token}"
        if not access_token or not hmac.compare_digest(request.headers.get("Authorization", ""), expected):
            return _error(401, "token de acesso inválido")

        try:
            body = await request.json()
        except (json.JSONDecodeError, UnicodeDecodeError):
            return _error(400, "corpo JSON inválido")

        text = body.get("text") if isinstance(body, dict) else None
        if (
            not isinstance(body, dict)
            or body.get("messaging_product") != "whatsapp"
            or not body.get("to")
            or not isinstance(text, dict)
            or not text.get("body")
        ):
            return _error(400, "messaging_product, to e text.body são obrigatórios")

        to = str(body["to"])
        received.write(
            {
                "channel": "whatsapp",
                "core_message_id": request.headers.get(CORE_MESSAGE_ID_HEADER),
                "recipient": to,
                "sender": request.match_info["phone_number_id"],
                "text": text["body"],
                "received_at": utc_now(),
                "traceparent": request.headers.get("traceparent"),
            }
        )
        return web.json_response(
            {
                "messaging_product": "whatsapp",
                "contacts": [{"input": to, "wa_id": to}],
                "messages": [{"id": new_message_id()}],
            }
        )

    return handle
