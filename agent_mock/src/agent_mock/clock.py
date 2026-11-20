"""Horários no formato do contrato: UTC com milissegundos, YYYY-MM-DDTHH:MM:SS.mmmZ."""

from datetime import datetime, timezone


def now() -> datetime:
    return datetime.now(timezone.utc)


def format_time(moment: datetime) -> str:
    """Horário em UTC no formato do contrato, com os milissegundos truncados."""
    moment = moment.astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def stamp() -> str:
    """Horário corrente no formato do contrato."""
    return format_time(now())


def from_millis(milliseconds: int) -> str:
    """Timestamp de registro Kafka (milissegundos Unix) no formato do contrato."""
    return format_time(datetime.fromtimestamp(milliseconds / 1000, timezone.utc))
