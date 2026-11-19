"""App aiohttp do serve: os receptores dos três canais.

| Rota | Função |
| - | - |
| POST /{versão}/{phone_number_id}/messages | Receptor do envio do WhatsApp (papel da Cloud API) |
| POST /chat/streams | Registro dos streams do chat, com o app_user_id |
| GET /health | Saúde do processo |

Tarefas de fundo: o cliente Action Cable (respostas do chat) e o poller do Mailpit (respostas por
e-mail). Todas as respostas vão para data/received.jsonl.
"""

import asyncio
import contextlib
import logging

from aiohttp import web

from .chat import CableClient, StreamRegistry, streams_handler
from .config import Settings
from .email import MailpitPoller
from .records import JsonlWriter
from .whatsapp import receiver

log = logging.getLogger(__name__)

RECEIVED_FILE = "received.jsonl"
STREAMS_FILE = "streams.jsonl"
MAILPIT_SEEN_FILE = "mailpit_seen.jsonl"

SETTINGS = web.AppKey("settings", Settings)
RECEIVED = web.AppKey("received", JsonlWriter)
REGISTRY = web.AppKey("registry", StreamRegistry)


async def health(_request: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


def create_app(settings: Settings, background: bool = True) -> web.Application:
    """App do serve. Com background=False, sobe só as rotas, sem cliente Action Cable e sem poller."""
    data_dir = settings.data_dir
    data_dir.mkdir(parents=True, exist_ok=True)
    received = JsonlWriter(data_dir / RECEIVED_FILE)
    registry = StreamRegistry(data_dir / STREAMS_FILE)

    app = web.Application()
    app[SETTINGS] = settings
    app[RECEIVED] = received
    app[REGISTRY] = registry
    app.router.add_post("/{version}/{phone_number_id}/messages", receiver(settings.whatsapp_access_token, received))
    app.router.add_post("/chat/streams", streams_handler(registry))
    app.router.add_get("/health", health)

    async def background_tasks(app: web.Application):
        tasks = []
        poller = None
        if background:
            cable = CableClient(settings.core_cable_url, settings.core_origin, registry, received)
            poller = MailpitPoller(
                settings.mailpit_api_url, received, data_dir / MAILPIT_SEEN_FILE, settings.mailpit_poll_seconds
            )
            tasks = [asyncio.create_task(cable.run()), asyncio.create_task(poller.run())]
        yield
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        if poller is not None:
            poller.close()
        registry.close()
        received.close()

    app.cleanup_ctx.append(background_tasks)
    return app


def serve(settings: Settings) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    web.run_app(create_app(settings), host="0.0.0.0", port=settings.port)
