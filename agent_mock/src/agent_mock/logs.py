"""Log JSON por linha no stdout.

Cada evento processado gera uma linha com result igual a um destes valores:

| result | Significado | Offset |
| - | - | - |
| published | Ação publicada e confirmada pelo Kafka | confirmado |
| discarded_newer | O contexto tem mensagem do lojista mais nova que o evento | confirmado |
| discarded_state | A conversa não está em with_ai | confirmado |
| context_error | O Core recusou o GET do contexto com erro permanente | confirmado |
| invalid_event | Registro sem os campos ou headers do contrato | confirmado |
| unknown_brand | Marca sem locale em AGENT_BRAND_LOCALES | confirmado |
"""

import json
import sys

from agent_mock import clock

PUBLISHED = "published"
DISCARDED_NEWER = "discarded_newer"
DISCARDED_STATE = "discarded_state"
CONTEXT_ERROR = "context_error"
INVALID_EVENT = "invalid_event"
UNKNOWN_BRAND = "unknown_brand"


def log(level: str, message: str, stream=None, **fields) -> None:
    line = {"time": clock.stamp(), "level": level, "message": message}
    line.update({key: value for key, value in fields.items() if value is not None})
    print(json.dumps(line, ensure_ascii=False, default=str), file=stream or sys.stdout, flush=True)


def info(message: str, **fields) -> None:
    log("info", message, **fields)


def warning(message: str, **fields) -> None:
    log("warning", message, **fields)


def error(message: str, **fields) -> None:
    log("error", message, **fields)
