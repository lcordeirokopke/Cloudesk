"""Configuração do simulador, lida do ambiente.

| Variável | Uso |
| - | - |
| CORE_URL | Base das entradas do Core |
| CORE_CABLE_URL, CORE_ORIGIN | WebSocket do Action Cable e header Origin |
| MAILPIT_API_URL | API do Mailpit, para o poller |
| SMTP_HOST, SMTP_PORT | SMTP do Mailpit, para o envio |
| WHATSAPP_APP_SECRET | Assinatura X-Hub-Signature-256 da entrada |
| WHATSAPP_VERIFY_TOKEN | Handshake GET do webhook |
| WHATSAPP_ACCESS_TOKEN | Bearer conferido no receptor |
| CHAT_SIGNING_SECRET | Assinatura da entrada do chat |
| PERSONAS_PATH | Arquivo exportado pela task simulator:personas |
| SIMULATOR_DATA_DIR | Pasta dos registros |
| SIMULATOR_PORT | Porta do serve |
| MAILPIT_POLL_SECONDS | Intervalo do poller do Mailpit |

Os comandos send e scenario registram os streams do chat no serve pelo endereço
http://localhost:<SIMULATOR_PORT>, porque rodam no mesmo contêiner (docker compose exec).
"""

import os
from dataclasses import dataclass
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]


@dataclass(frozen=True)
class Settings:
    core_url: str = "http://web:3000"
    core_cable_url: str = "ws://web:3000/cable"
    core_origin: str = "http://web:3000"
    mailpit_api_url: str = "http://mailpit:8025"
    smtp_host: str = "mailpit"
    smtp_port: int = 1025
    whatsapp_app_secret: str = ""
    whatsapp_verify_token: str = ""
    whatsapp_access_token: str = ""
    chat_signing_secret: str = ""
    personas_path: Path = REPOSITORY / "core" / "tmp" / "simulator" / "personas.json"
    data_dir: Path = REPOSITORY / "channel_simulator" / "data"
    port: int = 8080
    mailpit_poll_seconds: float = 2.0

    @property
    def simulator_url(self) -> str:
        return f"http://localhost:{self.port}"

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Settings":
        env = os.environ if env is None else env
        defaults = cls()

        def value(name: str, default):
            return env.get(name) or default

        return cls(
            core_url=value("CORE_URL", defaults.core_url).rstrip("/"),
            core_cable_url=value("CORE_CABLE_URL", defaults.core_cable_url),
            core_origin=value("CORE_ORIGIN", defaults.core_origin),
            mailpit_api_url=value("MAILPIT_API_URL", defaults.mailpit_api_url).rstrip("/"),
            smtp_host=value("SMTP_HOST", defaults.smtp_host),
            smtp_port=int(value("SMTP_PORT", defaults.smtp_port)),
            whatsapp_app_secret=value("WHATSAPP_APP_SECRET", ""),
            whatsapp_verify_token=value("WHATSAPP_VERIFY_TOKEN", ""),
            whatsapp_access_token=value("WHATSAPP_ACCESS_TOKEN", ""),
            chat_signing_secret=value("CHAT_SIGNING_SECRET", ""),
            personas_path=Path(value("PERSONAS_PATH", defaults.personas_path)),
            data_dir=Path(value("SIMULATOR_DATA_DIR", defaults.data_dir)),
            port=int(value("SIMULATOR_PORT", defaults.port)),
            mailpit_poll_seconds=float(value("MAILPIT_POLL_SECONDS", defaults.mailpit_poll_seconds)),
        )
