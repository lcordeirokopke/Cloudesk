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
| AGENT_FAILURE_MODE | none | Modo de falha: none, delay, drop, duplicate ou stale |
| AGENT_FAILURE_RATE | 1 | Fração dos eventos afetados pelo modo de falha, de 0 a 1 |
| AGENT_FAILURE_DELAY_MS | 0 | Atraso somado à latência no modo delay |
"""

import os
from dataclasses import dataclass, field

INBOUND_TOPIC = "agent.inbound"
OUTBOUND_TOPIC = "agent.outbound"
LOCALES = ("pt-BR", "en-US")
FAILURE_MODES = ("none", "delay", "drop", "duplicate", "stale")


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
    failure_mode: str = "none"
    failure_rate: float = 1.0
    failure_delay_ms: int = 0

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
            failure_mode=value("AGENT_FAILURE_MODE", defaults.failure_mode).strip(),
            failure_rate=float(value("AGENT_FAILURE_RATE", defaults.failure_rate)),
            failure_delay_ms=int(value("AGENT_FAILURE_DELAY_MS", defaults.failure_delay_ms)),
        )
        if settings.concurrency < 1:
            raise ValueError("AGENT_CONCURRENCY deve ser maior que zero")
        if settings.latency_ms < 0:
            raise ValueError("AGENT_LATENCY_MS não pode ser negativo")
        if settings.failure_mode not in FAILURE_MODES:
            raise ValueError(f"AGENT_FAILURE_MODE inválido: {settings.failure_mode!r}")
        if not 0 <= settings.failure_rate <= 1:
            raise ValueError("AGENT_FAILURE_RATE deve estar entre 0 e 1")
        if settings.failure_delay_ms < 0:
            raise ValueError("AGENT_FAILURE_DELAY_MS não pode ser negativo")
        return settings
