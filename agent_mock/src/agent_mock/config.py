"""Configuração do agente mock, lida do ambiente. É o único ponto de leitura de configuração.

| Variável | Padrão | Uso |
| - | - | - |
| KAFKA_BROKERS | redpanda:9092 | Endereços do Kafka, separados por vírgula |
| CORE_URL | http://web:3000 | Base da context_url |
| AGENT_CONTEXT_SECRET | | Assinatura do GET da context_url |
| AGENT_GROUP_ID | cloudesk-agent | Grupo de consumo de agent.inbound |
| AGENT_CONCURRENCY | 100 | Eventos em andamento por processo |
| AGENT_LATENCY_MS | 0 | Latência artificial fixa antes da publicação |
| AGENT_CONTEXT_TIMEOUT_SECONDS | 5 | Timeout de cada GET da context_url |
| AGENT_BRAND_LOCALES | infinitepay:pt-BR,jim:en-US | Locale de cada marca |
"""

import os
from dataclasses import dataclass, field

INBOUND_TOPIC = "agent.inbound"
OUTBOUND_TOPIC = "agent.outbound"
LOCALES = ("pt-BR", "en-US")


def parse_locales(value: str) -> dict[str, str]:
    """Pares marca:locale separados por vírgula."""
    locales = {}
    for pair in filter(None, (item.strip() for item in value.split(","))):
        brand, separator, locale = pair.partition(":")
        if not separator or not brand.strip() or locale.strip() not in LOCALES:
            raise ValueError(f"AGENT_BRAND_LOCALES inválido: {pair!r}")
        locales[brand.strip()] = locale.strip()
    return locales


@dataclass(frozen=True)
class Settings:
    kafka_brokers: str = "redpanda:9092"
    core_url: str = "http://web:3000"
    context_secret: str = ""
    group_id: str = "cloudesk-agent"
    concurrency: int = 100
    latency_ms: int = 0
    context_timeout_seconds: float = 5.0
    brand_locales: dict[str, str] = field(default_factory=lambda: {"infinitepay": "pt-BR", "jim": "en-US"})

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Settings":
        env = os.environ if env is None else env
        defaults = cls()

        def value(name: str, default):
            return env.get(name) or default

        settings = cls(
            kafka_brokers=value("KAFKA_BROKERS", defaults.kafka_brokers),
            core_url=value("CORE_URL", defaults.core_url).rstrip("/"),
            context_secret=value("AGENT_CONTEXT_SECRET", ""),
            group_id=value("AGENT_GROUP_ID", defaults.group_id),
            concurrency=int(value("AGENT_CONCURRENCY", defaults.concurrency)),
            latency_ms=int(value("AGENT_LATENCY_MS", defaults.latency_ms)),
            context_timeout_seconds=float(value("AGENT_CONTEXT_TIMEOUT_SECONDS", defaults.context_timeout_seconds)),
            brand_locales=parse_locales(env["AGENT_BRAND_LOCALES"]) if env.get("AGENT_BRAND_LOCALES")
            else defaults.brand_locales,
        )
        if settings.concurrency < 1:
            raise ValueError("AGENT_CONCURRENCY deve ser maior que zero")
        if settings.latency_ms < 0:
            raise ValueError("AGENT_LATENCY_MS não pode ser negativo")
        return settings
