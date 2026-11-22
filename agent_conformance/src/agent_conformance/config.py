"""Configuração do kit, lida do ambiente. É o único ponto de leitura de configuração.

| Variável | Padrão | Uso |
| - | - | - |
| KAFKA_BROKERS | redpanda:9092 | Endereços do Kafka, separados por vírgula |
| CONFORMANCE_INBOUND_TOPIC | conformance.inbound | Tópico em que o kit publica os eventos message.created |
| CONFORMANCE_OUTBOUND_TOPIC | conformance.outbound | Tópico em que o kit lê as ações do agente sob teste |
| CONFORMANCE_CONTEXT_SECRET | | Segredo do GET da context_url; o mesmo valor do AGENT_CONTEXT_SECRET do agente |
| CONFORMANCE_CORE_PORT | 8080 | Porta do Core falso |
| CONFORMANCE_ACTION_TIMEOUT_SECONDS | 15 | Espera máxima por uma ação ou por uma leitura do contexto |
| CONFORMANCE_QUIET_SECONDS | 5 | Tempo sem ação que confirma a ausência de ação |
| CONTRACTS_PATH | /contracts | Pasta do contrato, com v1/ dentro |
"""

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    kafka_brokers: str = "redpanda:9092"
    inbound_topic: str = "conformance.inbound"
    outbound_topic: str = "conformance.outbound"
    context_secret: str = ""
    core_port: int = 8080
    action_timeout_seconds: float = 15.0
    quiet_seconds: float = 5.0
    contracts_path: Path = Path("/contracts")

    @property
    def contracts(self) -> Path:
        return self.contracts_path / "v1"

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Settings":
        env = os.environ if env is None else env
        defaults = cls()

        def value(name: str, default):
            return env.get(name) or default

        settings = cls(
            kafka_brokers=value("KAFKA_BROKERS", defaults.kafka_brokers),
            inbound_topic=value("CONFORMANCE_INBOUND_TOPIC", defaults.inbound_topic),
            outbound_topic=value("CONFORMANCE_OUTBOUND_TOPIC", defaults.outbound_topic),
            context_secret=value("CONFORMANCE_CONTEXT_SECRET", ""),
            core_port=int(value("CONFORMANCE_CORE_PORT", defaults.core_port)),
            action_timeout_seconds=float(value("CONFORMANCE_ACTION_TIMEOUT_SECONDS", defaults.action_timeout_seconds)),
            quiet_seconds=float(value("CONFORMANCE_QUIET_SECONDS", defaults.quiet_seconds)),
            contracts_path=Path(value("CONTRACTS_PATH", defaults.contracts_path)),
        )
        if settings.action_timeout_seconds <= 0:
            raise ValueError("CONFORMANCE_ACTION_TIMEOUT_SECONDS deve ser maior que zero")
        if settings.quiet_seconds <= 0:
            raise ValueError("CONFORMANCE_QUIET_SECONDS deve ser maior que zero")
        return settings
