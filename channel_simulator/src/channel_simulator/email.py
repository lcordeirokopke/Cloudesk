"""E-mail: envio por SMTP ao Mailpit e recepção por polling da API do Mailpit.

Envio: From "<nome>" <e-mail do lojista>, To o e-mail de suporte da marca, Message-ID
<uuid4@simulator.cloudesk.test>, corpo text/plain e anexo opcional. O external_id registrado é o
Message-ID sem < e >, igual ao que o SupportMailbox do Core grava. O status é 250 quando o envio
termina sem exceção: o smtplib lança SMTPDataError para qualquer resposta diferente de 250 ao DATA,
e o destinatário único recusado vira SMTPRecipientsRefused.

Recepção: as respostas do Core chegam ao Mailpit e recebem do Core a tag cloudesk-ignored. A cada
MAILPIT_POLL_SECONDS, o poller busca essa tag, página a página (ordem decrescente de recebimento),
até uma página em que todos os IDs já foram vistos ou até o fim. Para cada ID novo, lê os headers;
com X-Cloudesk-Message-Id, grava a resposta em received.jsonl. O simulador não grava tags: o
PUT /api/v1/tags do Mailpit substitui todas as tags da mensagem. Os IDs vistos ficam em memória e
em data/mailpit_seen.jsonl, relido na partida.
"""

import asyncio
import logging
import smtplib
import uuid
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import formataddr
from pathlib import Path

import aiohttp

from .records import JsonlWriter, read_jsonl, utc_now
from .templates import Attachment

log = logging.getLogger(__name__)

MESSAGE_ID_DOMAIN = "simulator.cloudesk.test"
IGNORED_TAG = "cloudesk-ignored"
CORE_MESSAGE_ID_HEADER = "X-Cloudesk-Message-Id"
PAGE_SIZE = 50
SMTP_TIMEOUT = 10


def new_message_id() -> str:
    """Message-ID sem os sinais < e >; é o external_id do Core."""
    return f"{uuid.uuid4()}@{MESSAGE_ID_DOMAIN}"


def build(
    *,
    from_name: str,
    from_address: str,
    to_address: str,
    subject: str,
    text: str,
    message_id: str,
    attachment: Attachment | None = None,
) -> EmailMessage:
    message = EmailMessage()
    message["From"] = formataddr((from_name, from_address))
    message["To"] = to_address
    message["Subject"] = subject
    message["Message-ID"] = f"<{message_id}>"
    message.set_content(text)
    if attachment is not None:
        maintype, subtype = attachment.content_type.split("/", 1)
        message.add_attachment(attachment.data, maintype=maintype, subtype=subtype, filename=attachment.filename)
    return message


def send_sync(host: str, port: int, message: EmailMessage) -> tuple[int | str, str | None]:
    """Envia por SMTP. Devolve (status, erro): 250 e None no sucesso; no erro, o código SMTP quando a
    exceção traz um, senão o nome da exceção, e a mensagem do erro."""
    try:
        with smtplib.SMTP(host, port, timeout=SMTP_TIMEOUT) as smtp:
            smtp.send_message(message)
        return 250, None
    except smtplib.SMTPResponseException as error:
        return error.smtp_code, str(error)
    except smtplib.SMTPRecipientsRefused as error:
        codes = [code for code, _ in error.recipients.values()]
        return (codes[0] if codes else type(error).__name__), str(error)
    except (smtplib.SMTPException, OSError) as error:
        return type(error).__name__, str(error)


async def send(host: str, port: int, message: EmailMessage) -> tuple[int | str, str | None]:
    return await asyncio.to_thread(send_sync, host, port, message)


def _header(headers: dict, name: str) -> str | None:
    """Primeiro valor do header, sem diferenciar maiúsculas e minúsculas. A API do Mailpit devolve o
    valor bruto; as palavras codificadas da RFC 2047 (=?UTF-8?Q?...?=) são decodificadas."""
    for key, values in headers.items():
        if key.lower() == name.lower():
            value = (values[0] if values else None) if isinstance(values, list) else values
            return str(make_header(decode_header(value))) if value else value
    return None


class MailpitPoller:
    def __init__(self, api_url: str, received: JsonlWriter, seen_path: Path, interval: float = 2.0):
        self.api_url = api_url.rstrip("/")
        self.received = received
        self.interval = interval
        self.seen: set[str] = {record["mailpit_id"] for record in read_jsonl(seen_path)}
        self._seen_writer = JsonlWriter(seen_path)

    async def run(self) -> None:
        async with aiohttp.ClientSession() as session:
            while True:
                try:
                    await self.poll_once(session)
                except asyncio.CancelledError:
                    raise
                except Exception as error:  # noqa: BLE001 - Mailpit fora do ar: tenta no próximo ciclo
                    log.warning("Mailpit: %s: %s", type(error).__name__, error)
                await asyncio.sleep(self.interval)

    async def poll_once(self, session: aiohttp.ClientSession) -> int:
        """Um ciclo de busca. Devolve quantas respostas foram gravadas."""
        recorded = 0
        start = 0
        while True:
            page = await self._search(session, start)
            messages = page.get("messages") or []
            if not messages:
                break

            new_ids = [message["ID"] for message in messages if message["ID"] not in self.seen]
            for mailpit_id in new_ids:
                recorded += await self._handle(session, mailpit_id)

            start += len(messages)
            if not new_ids or start >= int(page.get("messages_count") or 0):
                break
        return recorded

    async def _search(self, session: aiohttp.ClientSession, start: int) -> dict:
        params = {"query": f"tag:{IGNORED_TAG}", "start": str(start), "limit": str(PAGE_SIZE)}
        async with session.get(f"{self.api_url}/api/v1/search", params=params) as response:
            response.raise_for_status()
            return await response.json()

    async def _handle(self, session: aiohttp.ClientSession, mailpit_id: str) -> int:
        async with session.get(f"{self.api_url}/api/v1/message/{mailpit_id}/headers") as response:
            response.raise_for_status()
            headers = await response.json()

        core_message_id = _header(headers, CORE_MESSAGE_ID_HEADER)
        if core_message_id:
            self.received.write(
                {
                    "channel": "email",
                    "core_message_id": core_message_id,
                    "recipient": _header(headers, "To"),
                    "sender": _header(headers, "From"),
                    "subject": _header(headers, "Subject"),
                    "received_at": utc_now(),
                    "mailpit_id": mailpit_id,
                }
            )

        self.seen.add(mailpit_id)
        self._seen_writer.write({"mailpit_id": mailpit_id})
        return 1 if core_message_id else 0

    def close(self) -> None:
        self._seen_writer.close()
