"""Geração de tráfego: o comando send, com taxa controlada, e o cenário entre canais.

Cada execução tem um run_id (horário UTC mais quatro caracteres aleatórios) e grava
data/runs/<run_id>/sent.jsonl, uma linha por mensagem:

| Campo | Conteúdo |
| - | - |
| run_id, channel, brand | Execução, canal e marca |
| contacts | seed (lojista das seeds) ou new (lojista novo) |
| identity | Telefone, e-mail ou app_user_id do lojista |
| external_id | wamid, Message-ID sem < e > ou client_message_id |
| intent, urgent, attachment | Intenção do texto, se leva frase de urgência e tipo do anexo, ou null |
| sent_at, status, duration_ms | Início do envio, status HTTP (ou 250 no SMTP) e duração |
| conversation_id, sequence, stream_status | Só no chat: resposta do Core e status do registro do stream |
| error | Só quando a montagem ou o envio falha; o status é então o nome da exceção (ou o código SMTP) |

A semente define marca, canal, lojista, intenção, urgência e texto de cada mensagem; os ids externos são
únicos a cada execução.
"""

import asyncio
import random
import secrets
import string
import time
import uuid
from collections import Counter
from dataclasses import dataclass
from datetime import UTC, datetime

import aiohttp

from . import chat, email, templates, whatsapp
from .config import Settings
from .personas import Brand, Contact, Personas, WhatsappNumber, new_contact
from .records import JsonlWriter, utc_now

CHANNELS = ("whatsapp", "chat", "email")
CROSS_CHANNEL_ORDER = ("whatsapp", "chat", "email")


@dataclass(frozen=True)
class SendOptions:
    channel: str = "all"
    brand: str = "all"
    count: int = 1
    rate: float = 1.0
    contacts: str = "seed"
    attachments: float = 0.0
    urgency: float = 0.0
    seed: int = 1


def new_run_id() -> str:
    suffix = "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(4))
    return f"{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}-{suffix}"


@dataclass(frozen=True)
class Planned:
    brand: Brand
    channel: str
    contact: Contact
    content: templates.Content
    whatsapp_number: WhatsappNumber
    support_email: str


def planned_text(brand: Brand, channel: str, contact: Contact, text: str, intent: str, rng: random.Random) -> Planned:
    """Mensagem com lojista e texto dados, sem anexo; o rng escolhe o número e o e-mail da marca."""
    return Planned(
        brand=brand,
        channel=channel,
        contact=contact,
        content=templates.Content(intent=intent, text=text, subject=text[:60], attachment=None),
        whatsapp_number=rng.choice(brand.whatsapp_numbers),
        support_email=rng.choice(brand.support_emails),
    )


def plan(personas: Personas, options: SendOptions, rng: random.Random) -> Planned:
    """Sorteia uma mensagem com o rng da execução."""
    brands = personas.brands if options.brand == "all" else (personas.brand(options.brand),)
    channels = CHANNELS if options.channel == "all" else (options.channel,)

    brand = rng.choice(brands)
    channel = rng.choice(channels)
    if options.contacts == "new":
        contact = new_contact(brand, rng)
    else:
        if not brand.contacts:
            raise ValueError(f"a marca {brand.slug} não tem lojistas no personas.json")
        contact = rng.choice(brand.contacts)
    content = templates.generate(
        rng, brand.locale, attachment_ratio=options.attachments, urgency_ratio=options.urgency
    )

    return Planned(
        brand=brand,
        channel=channel,
        contact=contact,
        content=content,
        whatsapp_number=rng.choice(brand.whatsapp_numbers),
        support_email=rng.choice(brand.support_emails),
    )


async def send_one(session: aiohttp.ClientSession, settings: Settings, run_id: str, item: Planned) -> dict:
    """Envia uma mensagem e devolve o registro de sent.jsonl."""
    content = item.content
    record = {
        "run_id": run_id,
        "channel": item.channel,
        "brand": item.brand.slug,
        "contacts": item.contact.origin,
        "identity": item.contact.identity(item.channel),
        "external_id": None,
        "intent": content.intent,
        "urgent": content.urgent,
        "attachment": content.attachment.kind if content.attachment else None,
        "sent_at": utc_now(),
    }
    started = time.perf_counter()

    try:
        if item.channel == "whatsapp":
            message_id = whatsapp.new_message_id()
            record["external_id"] = message_id
            payload = whatsapp.build_payload(
                phone_number_id=item.whatsapp_number.phone_number_id,
                display_phone_number=item.whatsapp_number.display,
                contact_name=item.contact.name,
                wa_id=item.contact.whatsapp,
                message_id=message_id,
                text=content.text,
                attachment=content.attachment.metadata() if content.attachment else None,
            )
            record["status"] = await whatsapp.send(session, settings.core_url, settings.whatsapp_app_secret, payload)

        elif item.channel == "chat":
            client_message_id = str(uuid.uuid4())
            record["external_id"] = client_message_id
            body = chat.build_body(
                item.brand.slug,
                item.contact.chat,
                client_message_id,
                content.text,
                [content.attachment.metadata()] if content.attachment else [],
            )
            status, data = await chat.send(session, settings.core_url, settings.chat_signing_secret, body)
            record["status"] = status
            data = data or {}
            record["conversation_id"] = data.get("conversation_id")
            record["sequence"] = data.get("sequence")
            stream = data.get("stream")
            if stream:
                try:
                    record["stream_status"] = await chat.register_stream(
                        session, settings.simulator_url, stream, item.contact.chat
                    )
                except aiohttp.ClientError as error:
                    record["stream_status"] = type(error).__name__

        else:
            message_id = email.new_message_id()
            record["external_id"] = message_id
            message = email.build(
                from_name=item.contact.name,
                from_address=item.contact.email,
                to_address=item.support_email,
                subject=content.subject,
                text=content.text,
                message_id=message_id,
                attachment=content.attachment,
            )
            status, error = await email.send(settings.smtp_host, settings.smtp_port, message)
            record["status"] = status
            if error:
                record["error"] = error

    except Exception as error:  # noqa: BLE001 - toda falha de montagem ou envio vira registro; o comando segue
        record["status"] = type(error).__name__
        record["error"] = str(error)

    record["duration_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return record


def _summary(run_id: str, records: list[dict]) -> dict:
    return {
        "run_id": run_id,
        "sent": len(records),
        "status": dict(Counter(f"{record['channel']}:{record['status']}" for record in records)),
    }


async def run_send(settings: Settings, personas: Personas, options: SendOptions, run_id: str | None = None) -> dict:
    """Envia options.count mensagens na taxa options.rate (msg/s) e devolve o resumo."""
    if options.count < 1:
        raise ValueError("count deve ser maior que zero")
    if options.rate <= 0:
        raise ValueError("rate deve ser maior que zero")
    if not 0 <= options.attachments <= 1:
        raise ValueError("attachments deve estar entre 0 e 1")

    run_id = run_id or new_run_id()
    rng = random.Random(options.seed)
    items = [plan(personas, options, rng) for _ in range(options.count)]
    records: list[dict] = []

    with JsonlWriter(settings.data_dir / "runs" / run_id / "sent.jsonl") as writer:
        async with aiohttp.ClientSession() as session:

            async def scheduled(index: int, item: Planned, start: float) -> None:
                delay = start + index / options.rate - time.perf_counter()
                if delay > 0:
                    await asyncio.sleep(delay)
                record = await send_one(session, settings, run_id, item)
                writer.write(record)
                records.append(record)

            start = time.perf_counter()
            await asyncio.gather(*(scheduled(index, item, start) for index, item in enumerate(items)))

    return _summary(run_id, records)


async def run_cross_channel(settings: Settings, personas: Personas, brand_slug: str, seed: int) -> dict:
    """Um lojista das seeds escreve por WhatsApp, chat e e-mail, nessa ordem."""
    rng = random.Random(seed)
    brand = personas.brand(brand_slug)
    if not brand.contacts:
        raise ValueError(f"a marca {brand.slug} não tem lojistas no personas.json")
    contact = rng.choice(brand.contacts)
    run_id = new_run_id()
    records: list[dict] = []

    with JsonlWriter(settings.data_dir / "runs" / run_id / "sent.jsonl") as writer:
        async with aiohttp.ClientSession() as session:
            for channel in CROSS_CHANNEL_ORDER:
                item = Planned(
                    brand=brand,
                    channel=channel,
                    contact=contact,
                    content=templates.generate(rng, brand.locale),
                    whatsapp_number=rng.choice(brand.whatsapp_numbers),
                    support_email=rng.choice(brand.support_emails),
                )
                record = await send_one(session, settings, run_id, item)
                writer.write(record)
                records.append(record)

    chat_record = next(record for record in records if record["channel"] == "chat")
    return {**_summary(run_id, records), "contact": contact.name, "conversation_id": chat_record.get("conversation_id")}
