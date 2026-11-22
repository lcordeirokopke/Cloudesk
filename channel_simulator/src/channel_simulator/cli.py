"""Linha de comando do simulador.

| Comando | Efeito |
| - | - |
| channel-simulator serve | Sobe os receptores dos três canais |
| channel-simulator send | Envia mensagens sintéticas na taxa pedida |
| channel-simulator scenario cross-channel | Um lojista das seeds escreve por WhatsApp, chat e e-mail |
| channel-simulator scenario <cenário de demonstração> | Lojista novo, passos fixos e conferência no canal (scenarios); termina com 1 quando uma expectativa falha |
| channel-simulator scenario memory --continue <run_id> | Parte 2 do cenário memory, com o lojista da parte 1 |
| channel-simulator verify-whatsapp | Handshake GET do webhook do WhatsApp |
"""

import argparse
import asyncio
import json
import sys

import aiohttp

from . import personas, scenarios, whatsapp
from .config import Settings
from .sender import SendOptions, run_cross_channel, run_send


def _ratio(value: str) -> float:
    number = float(value)
    if not 0 <= number <= 1:
        raise argparse.ArgumentTypeError("deve estar entre 0 e 1")
    return number


def _positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("deve ser maior que zero")
    return number


def _positive_float(value: str) -> float:
    number = float(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("deve ser maior que zero")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="channel-simulator", description="Simulador de canais do Cloudesk")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("serve", help="sobe os receptores dos três canais")

    send = commands.add_parser("send", help="envia mensagens sintéticas")
    send.add_argument("--channel", choices=["whatsapp", "chat", "email", "all"], default="all")
    send.add_argument("--brand", choices=["infinitepay", "jim", "all"], default="all")
    send.add_argument("--count", type=_positive_int, default=1)
    send.add_argument("--rate", type=_positive_float, default=1.0, help="mensagens por segundo")
    send.add_argument("--contacts", choices=["seed", "new"], default="seed")
    send.add_argument("--attachments", type=_ratio, default=0.0, help="fração de mensagens com anexo, de 0 a 1")
    send.add_argument(
        "--urgency-ratio", type=_ratio, default=0.0, help="fração de mensagens com frase de urgência, de 0 a 1"
    )
    send.add_argument("--seed", type=int, default=1)

    scenario = commands.add_parser("scenario", help="cenários prontos")
    scenario.add_argument("name", choices=["cross-channel", *scenarios.NAMES])
    scenario.add_argument("--brand", choices=["infinitepay", "jim"], default="infinitepay")
    scenario.add_argument("--seed", type=int, default=1)
    scenario.add_argument("--continue", dest="continue_run", metavar="RUN_ID",
                          help="parte 2 do cenário memory, com o run_id da parte 1")

    commands.add_parser("verify-whatsapp", help="handshake GET do webhook do WhatsApp")
    return parser


async def _verify(settings: Settings) -> int:
    async with aiohttp.ClientSession() as session:
        ok, status, body = await whatsapp.verify(session, settings.core_url, settings.whatsapp_verify_token)
    print(json.dumps({"verified": ok, "status": status, "body": body}, ensure_ascii=False))
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    settings = Settings.from_env()

    if args.command == "serve":
        from .server import serve

        serve(settings)
        return 0

    if args.command == "verify-whatsapp":
        return asyncio.run(_verify(settings))

    loaded = personas.load(settings.personas_path)
    if args.command == "scenario" and args.continue_run and args.name != "memory":
        build_parser().error("--continue só vale com o cenário memory")
    if args.command == "scenario" and args.name != "cross-channel":
        return asyncio.run(
            scenarios.run_scenario(settings, loaded, args.name, args.brand, args.seed, args.continue_run)
        )
    if args.command == "send":
        options = SendOptions(
            channel=args.channel,
            brand=args.brand,
            count=args.count,
            rate=args.rate,
            contacts=args.contacts,
            attachments=args.attachments,
            urgency=args.urgency_ratio,
            seed=args.seed,
        )
        result = asyncio.run(run_send(settings, loaded, options))
    else:
        result = asyncio.run(run_cross_channel(settings, loaded, args.brand, args.seed))

    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
