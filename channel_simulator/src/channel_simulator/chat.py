"""Chat in-app: entrada JSON assinada e saída por Turbo Stream sobre Action Cable.

Envio: POST {CORE_URL}/channels/chat/messages com { brand, app_user_id, client_message_id, text,
attachments }, assinado com a assinatura do contrato (CHAT_SIGNING_SECRET). A resposta 200 traz
conversation_id, sequence e stream, o nome assinado do stream Turbo do lojista.

Registro de streams: POST /chat/streams no serve, com {"stream", "app_user_id"}. O stream é por
lojista; o mesmo stream com outro app_user_id é erro de quem chamou e recebe 409, mantendo o par
original. Os pares ficam em memória e em data/streams.jsonl, relido na partida do serve.

Recepção: o cliente Action Cable conecta em CORE_CABLE_URL com Origin CORE_ORIGIN, assina cada
stream no Turbo::StreamsChannel e grava em received.jsonl as mensagens de autor diferente de
customer. Na queda da conexão, reconecta com backoff exponencial e assina de novo todos os streams.
Uma conexão sem welcome ou sem ping além de STALE_THRESHOLD também é refeita.
"""

import asyncio
import contextlib
import json
import logging
from collections.abc import Callable
from html.parser import HTMLParser
from pathlib import Path

import aiohttp
from aiohttp import web

from . import signature
from .records import JsonlWriter, read_jsonl, utc_now

log = logging.getLogger(__name__)

MESSAGES_PATH = "/channels/chat/messages"
STREAMS_PATH = "/chat/streams"
CABLE_PROTOCOL = "actioncable-v1-json"
STREAMS_CHANNEL = "Turbo::StreamsChannel"

# O servidor do Action Cable envia ping a cada 3 s (BEAT_INTERVAL na gem actioncable 8.1.4.1). Como
# o ConnectionMonitor do cliente JS oficial (staleThreshold = 6), a conexão sem welcome ou sem
# nenhum frame por 6 s é dada como parada e refeita.
STALE_THRESHOLD = 6.0


# Envio


def build_body(brand: str, app_user_id: str, client_message_id: str, text: str, attachments: list[dict]) -> str:
    return json.dumps(
        {
            "brand": brand,
            "app_user_id": app_user_id,
            "client_message_id": client_message_id,
            "text": text,
            "attachments": attachments,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


async def send(session: aiohttp.ClientSession, core_url: str, secret: str, body: str) -> tuple[int, dict | None]:
    """Envia a mensagem ao Core. Devolve o status e o JSON da resposta, quando houver."""
    headers = {"Content-Type": "application/json", **signature.headers(secret, "POST", MESSAGES_PATH, body)}
    async with session.post(f"{core_url}{MESSAGES_PATH}", data=body.encode("utf-8"), headers=headers) as response:
        try:
            data = await response.json(content_type=None)
        except (json.JSONDecodeError, aiohttp.ContentTypeError):
            data = None
        return response.status, data if isinstance(data, dict) else None


async def register_stream(session: aiohttp.ClientSession, simulator_url: str, stream: str, app_user_id: str) -> int:
    """Registra o stream no serve e devolve o status HTTP."""
    async with session.post(
        f"{simulator_url}{STREAMS_PATH}", json={"stream": stream, "app_user_id": app_user_id}
    ) as response:
        await response.read()
        return response.status


# Registro de streams


class StreamRegistry:
    """Pares stream → app_user_id, persistidos em JSONL."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._streams: dict[str, str] = {}
        for record in read_jsonl(self.path):
            self._streams.setdefault(record["stream"], record["app_user_id"])
        self._writer = JsonlWriter(self.path)
        self._listeners: list[Callable[[str], None]] = []

    def __contains__(self, stream: str) -> bool:
        return stream in self._streams

    def streams(self) -> list[str]:
        return list(self._streams)

    def app_user_id(self, stream: str) -> str | None:
        return self._streams.get(stream)

    def add_listener(self, listener: Callable[[str], None]) -> None:
        self._listeners.append(listener)

    def register(self, stream: str, app_user_id: str) -> str:
        """Devolve "created", "exists" (mesmo par) ou "conflict" (stream com outro app_user_id)."""
        current = self._streams.get(stream)
        if current == app_user_id:
            return "exists"
        if current is not None:
            return "conflict"

        self._streams[stream] = app_user_id
        self._writer.write({"stream": stream, "app_user_id": app_user_id, "registered_at": utc_now()})
        for listener in self._listeners:
            listener(stream)
        return "created"

    def close(self) -> None:
        self._writer.close()


def streams_handler(registry: StreamRegistry):
    """Handler de POST /chat/streams."""

    async def handle(request: web.Request) -> web.Response:
        try:
            body = await request.json()
        except (json.JSONDecodeError, UnicodeDecodeError):
            body = None

        stream = body.get("stream") if isinstance(body, dict) else None
        app_user_id = body.get("app_user_id") if isinstance(body, dict) else None
        if not isinstance(stream, str) or not stream or not isinstance(app_user_id, str) or not app_user_id:
            return web.json_response({"error": "stream e app_user_id são obrigatórios"}, status=400)

        result = registry.register(stream, app_user_id)
        if result == "conflict":
            return web.json_response(
                {"error": "stream já registrado com outro app_user_id", "app_user_id": registry.app_user_id(stream)},
                status=409,
            )
        return web.json_response({"stream": stream, "app_user_id": app_user_id, "result": result})

    return handle


# Parser do Turbo Stream


class _MessageParser(HTMLParser):
    """Lê o partial channels/chat/_message.html.erb dentro do <turbo-stream>."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.message: dict | None = None
        self._in_body = False
        self._body: list[str] = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        classes = (attributes.get("class") or "").split()
        if tag == "div" and self.message is None and "chat-message" in classes:
            author = next(
                (name.removeprefix("chat-message-") for name in classes if name.startswith("chat-message-")), None
            )
            element_id = attributes.get("id") or ""
            sequence = attributes.get("data-sequence")
            self.message = {
                "core_message_id": element_id.removeprefix("message_") or None,
                "sequence": int(sequence) if sequence and sequence.isdigit() else None,
                "channel": attributes.get("data-channel"),
                "author": author,
            }
        elif tag == "p" and "chat-message__body" in classes:
            self._in_body = True

    def handle_endtag(self, tag):
        if tag == "p" and self._in_body:
            self._in_body = False

    def handle_data(self, data):
        if self._in_body:
            self._body.append(data)

    def result(self) -> dict | None:
        if self.message is None:
            return None
        return {**self.message, "text": "".join(self._body).strip()}


def parse_turbo_stream(html: str) -> dict | None:
    """Mensagem do partial: core_message_id, sequence, channel, author e text; None se não houver."""
    parser = _MessageParser()
    parser.feed(html)
    parser.close()
    return parser.result()


# Cliente Action Cable


def identifier(stream: str) -> str:
    return json.dumps({"channel": STREAMS_CHANNEL, "signed_stream_name": stream}, separators=(",", ":"))


class CableClient:
    """Cliente do Action Cable que grava as respostas do chat em received.jsonl."""

    def __init__(
        self,
        url: str,
        origin: str,
        registry: StreamRegistry,
        received: JsonlWriter,
        initial_backoff: float = 0.5,
        max_backoff: float = 30.0,
        stale_threshold: float = STALE_THRESHOLD,
    ):
        self.url = url
        self.origin = origin
        self.registry = registry
        self.received = received
        self.initial_backoff = initial_backoff
        self.max_backoff = max_backoff
        self.stale_threshold = stale_threshold
        self.connected = asyncio.Event()
        self.connections = 0
        self._pending: asyncio.Queue[str] = asyncio.Queue()
        registry.add_listener(self._pending.put_nowait)

    async def run(self) -> None:
        backoff = self.initial_backoff
        async with aiohttp.ClientSession() as session:
            while True:
                try:
                    await self._connect(session)
                    backoff = self.initial_backoff
                except asyncio.CancelledError:
                    raise
                except Exception as error:  # noqa: BLE001 - qualquer falha leva à reconexão
                    log.warning("Action Cable: %s: %s", type(error).__name__, error)
                finally:
                    self.connected.clear()
                log.info("Action Cable: reconectando em %.1f s", backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, self.max_backoff)

    async def _connect(self, session: aiohttp.ClientSession) -> None:
        async with session.ws_connect(self.url, protocols=(CABLE_PROTOCOL,), headers={"Origin": self.origin}) as ws:
            self.connections += 1
            subscribed: set[str] = set()
            pending = asyncio.create_task(self._subscribe_pending(ws, subscribed))
            loop = asyncio.get_running_loop()
            welcome_deadline = loop.time() + self.stale_threshold
            welcomed = False
            try:
                while True:
                    timeout = self.stale_threshold if welcomed else welcome_deadline - loop.time()
                    if timeout <= 0:
                        log.warning("Action Cable: sem welcome em %.1f s; reconectando", self.stale_threshold)
                        break
                    try:
                        frame = await ws.receive(timeout=timeout)
                    except TimeoutError:
                        log.warning(
                            "Action Cable: %s em %.1f s; reconectando",
                            "conexão parada, sem ping" if welcomed else "sem welcome",
                            self.stale_threshold,
                        )
                        break
                    if frame.type != aiohttp.WSMsgType.TEXT:
                        break
                    data = json.loads(frame.data)
                    kind = data.get("type")
                    if kind == "welcome":
                        welcomed = True
                        streams = self.registry.streams()
                        log.info("Action Cable: conectado; assinando %d stream(s)", len(streams))
                        for stream in streams:
                            await self._subscribe(ws, stream, subscribed)
                        self.connected.set()
                    elif kind == "disconnect":
                        log.warning("Action Cable: disconnect (%s)", data.get("reason"))
                        break
                    elif kind == "reject_subscription":
                        log.warning("Action Cable: assinatura recusada: %s", data.get("identifier"))
                    elif kind in ("ping", "confirm_subscription"):
                        continue
                    elif "message" in data:
                        self._record(data)
            finally:
                pending.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await pending

    async def _subscribe_pending(self, ws, subscribed: set[str]) -> None:
        """Assina os streams registrados com a conexão aberta. Uma falha fecha a conexão: a
        reconexão assina de novo todos os streams do registro."""
        try:
            while True:
                stream = await self._pending.get()
                await self.connected.wait()
                await self._subscribe(ws, stream, subscribed)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001
            log.warning("Action Cable: falha ao assinar (%s: %s); reconectando", type(error).__name__, error)
            await ws.close()

    async def _subscribe(self, ws, stream: str, subscribed: set[str]) -> None:
        if stream in subscribed or ws.closed:
            return
        subscribed.add(stream)
        await ws.send_str(json.dumps({"command": "subscribe", "identifier": identifier(stream)}))
        log.info("Action Cable: assinatura enviada para %s", self.registry.app_user_id(stream))

    def _record(self, data: dict) -> None:
        payload = data.get("message")
        if not isinstance(payload, str):
            return
        message = parse_turbo_stream(payload)
        if message is None or message["author"] == "customer":
            return

        try:
            stream = json.loads(data.get("identifier") or "{}").get("signed_stream_name")
        except json.JSONDecodeError:
            stream = None
        self.received.write(
            {
                "channel": "chat",
                "core_message_id": message["core_message_id"],
                "recipient": self.registry.app_user_id(stream) if stream else None,
                "stream": stream,
                "sender": None,
                "author": message["author"],
                "text": message["text"],
                "received_at": utc_now(),
                "sequence": message["sequence"],
            }
        )
