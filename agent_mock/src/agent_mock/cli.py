"""Linha de comando do agente mock.

    agent-mock run    consome AGENT_INBOUND_TOPIC (agent.inbound) e publica as ações em
                      AGENT_OUTBOUND_TOPIC (agent.outbound)

SIGTERM e SIGINT param a leitura, esperam os eventos em andamento por alguns segundos e confirmam
os offsets concluídos.
"""

import argparse
import asyncio
import signal

from agent_mock.config import Settings
from agent_mock.runner import Runner


async def run(settings: Settings) -> None:
    runner = Runner(settings)
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(signum, runner.stop)
        except NotImplementedError:
            pass
    await runner.run()


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="agent-mock", description="Agente mock do Cloudesk")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("run", help="consome o tópico de entrada e publica as ações no tópico de saída")
    arguments = parser.parse_args(argv)

    if arguments.command == "run":
        asyncio.run(run(Settings.from_env()))


if __name__ == "__main__":
    main()
