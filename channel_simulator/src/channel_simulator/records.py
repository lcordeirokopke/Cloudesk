"""Registros em JSONL: uma linha JSON por registro, gravada com append e flush por linha.

| Arquivo | Conteúdo |
| - | - |
| data/runs/<run_id>/sent.jsonl | Mensagens enviadas por uma execução de send ou scenario |
| data/received.jsonl | Respostas recebidas pelo serve, nos três canais |
| data/streams.jsonl | Streams do chat registrados, com o app_user_id |
| data/mailpit_seen.jsonl | IDs do Mailpit já tratados pelo poller |

A reconciliação da F18 compara sent.jsonl com received.jsonl; uma resposta duplicada é o mesmo
core_message_id recebido duas vezes.
"""

import json
from datetime import UTC, datetime
from pathlib import Path


def utc_now() -> str:
    """Horário UTC em ISO 8601 com milissegundos."""
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class JsonlWriter:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self.path.open("a", encoding="utf-8")

    def write(self, record: dict) -> None:
        self._file.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        self._file.flush()

    def close(self) -> None:
        self._file.close()

    def __enter__(self) -> "JsonlWriter":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


def read_jsonl(path: Path) -> list[dict]:
    """Registros do arquivo; lista vazia quando ele não existe. Linhas em branco são ignoradas."""
    path = Path(path)
    if not path.exists():
        return []

    with path.open(encoding="utf-8") as file:
        return [json.loads(line) for line in file if line.strip()]
