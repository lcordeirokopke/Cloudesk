"""Backlog ao longo da etapa e critérios da H1.

Backlog: jobs prontos e em execução das filas webhooks, channels e default, mais o lag dos grupos
cloudesk-agent e cloudesk-broker. As séries são reamostradas em 15 s, o intervalo do lag.

A etapa é sustentada quando:
  a) descartado o primeiro minuto, o limite superior do IC 95% da inclinação do backlog fica abaixo
     de 1% da taxa;
  b) a taxa aceita é de pelo menos 99% da pedida, com dropped_iterations e falhas abaixo de 1%;
  c) o backlog zera em até 60 s depois do fim da carga.

Backlog zerado: duas amostras seguidas com no máximo 5 jobs prontos ou em execução nas três filas,
lag 0 nos dois grupos e nenhum job agendado de webhooks ou channels. Vale o horário da primeira das
duas amostras.
"""

from dataclasses import dataclass

import numpy as np
import pandas as pd
from scipy import stats

QUEUES = ("webhooks", "channels", "default")
SCHEDULED_QUEUES = ("webhooks", "channels")
GROUPS = ("cloudesk-agent", "cloudesk-broker")
GRID_SECONDS = 15
WARMUP_SECONDS = 60
SLOPE_SHARE = 0.01
MIN_ACCEPTED = 0.99
MAX_FAILURES = 0.01
ZERO_MAX_JOBS = 5
ZERO_LIMIT_SECONDS = 60


def grid(start: float, end: float) -> np.ndarray:
    return np.arange(start, end + 0.001, GRID_SECONDS)


def sample(frame: pd.DataFrame, times: np.ndarray) -> np.ndarray:
    """Soma, em cada instante, da última amostra de cada série até ele; 0 sem amostra."""
    total = np.zeros(len(times))
    if frame.empty:
        return total
    for _, rows in frame.groupby("labels"):
        rows = rows.sort_values("timestamp")
        positions = np.searchsorted(rows["timestamp"].to_numpy(), times, side="right") - 1
        values = rows["value"].to_numpy()
        total += np.where(positions >= 0, values[np.maximum(positions, 0)], 0.0)
    return total


def _select(frame: pd.DataFrame, **labels) -> pd.DataFrame:
    for name, accepted in labels.items():
        if frame.empty:
            return frame
        frame = frame[frame[name].isin(accepted)]
    return frame


def series(jobs: pd.DataFrame, lag: pd.DataFrame, start: float, end: float) -> pd.DataFrame:
    """Uma linha por instante da grade: jobs por fila, agendados, lag por grupo e backlog."""
    times = grid(start, end)
    columns = {"timestamp": times, "elapsed": times - start}
    for queue in QUEUES:
        columns[queue] = sample(_select(jobs, queue=[queue], state=["ready", "claimed"]), times)
    columns["scheduled"] = sample(_select(jobs, queue=SCHEDULED_QUEUES, state=["scheduled"]), times)
    for group in GROUPS:
        columns[group] = sample(_select(lag, redpanda_group=[group]), times)
    frame = pd.DataFrame(columns)
    frame["jobs"] = frame[list(QUEUES)].sum(axis=1)
    frame["lag"] = frame[list(GROUPS)].sum(axis=1)
    frame["backlog"] = frame["jobs"] + frame["lag"]
    return frame


@dataclass(frozen=True)
class Slope:
    slope: float
    upper: float
    limit: float
    samples: int

    @property
    def ok(self) -> bool:
        return self.upper < self.limit


def slope(frame: pd.DataFrame, rate: float, duration: float) -> Slope:
    """Critério (a): regressão do backlog de 60 s até o fim da carga."""
    window = frame[(frame["elapsed"] >= WARMUP_SECONDS) & (frame["elapsed"] <= duration)]
    if len(window) < 3:
        raise ValueError(f"{len(window)} amostra(s) de backlog depois do primeiro minuto; são necessárias 3")
    limit = SLOPE_SHARE * rate
    # Backlog constante: inclinação 0 sem resíduo; o linregress devolve NaN no erro padrão.
    if window["backlog"].nunique() == 1:
        return Slope(slope=0.0, upper=0.0, limit=limit, samples=len(window))
    regression = stats.linregress(window["elapsed"], window["backlog"])
    margin = stats.t.ppf(0.975, len(window) - 2) * regression.stderr
    return Slope(slope=float(regression.slope), upper=float(regression.slope + margin), limit=limit, samples=len(window))


@dataclass(frozen=True)
class Acceptance:
    planned: float
    sent: int
    accepted: int
    dropped: int

    @property
    def accepted_share(self) -> float:
        return self.accepted / self.planned if self.planned else 0.0

    @property
    def dropped_share(self) -> float:
        return self.dropped / self.planned if self.planned else 0.0

    @property
    def failed_share(self) -> float:
        return (self.sent - self.accepted) / self.sent if self.sent else 0.0

    @property
    def ok(self) -> bool:
        return (self.accepted_share >= MIN_ACCEPTED and self.dropped_share < MAX_FAILURES
                and self.failed_share < MAX_FAILURES)


def acceptance(sent: pd.DataFrame, rate: float, duration: float, dropped: int = 0) -> Acceptance:
    """Critério (b): respostas 200 divididas pela taxa vezes a duração."""
    accepted = int((sent["status"] == 200).sum()) if len(sent) else 0
    return Acceptance(planned=rate * duration, sent=len(sent), accepted=accepted, dropped=int(dropped))


def zero_after(frame: pd.DataFrame) -> float | None:
    """Segundos, desde o início da série, até a primeira de duas amostras zeradas seguidas."""
    zero = ((frame["jobs"] <= ZERO_MAX_JOBS) & (frame["lag"] == 0) & (frame["scheduled"] == 0)).to_numpy()
    for index in range(len(zero) - 1):
        if zero[index] and zero[index + 1]:
            return float(frame["elapsed"].iloc[index])
    return None


def zero_ok(seconds: float | None) -> bool:
    return seconds is not None and seconds <= ZERO_LIMIT_SECONDS


def h1(jobs: pd.DataFrame, lag: pd.DataFrame, sent: pd.DataFrame, rate: float, start: float, load_end: float,
       capture_end: float, dropped: int) -> dict:
    """Os três critérios da etapa, com os números que os decidem. load_end menos start é a duração."""
    duration = load_end - start
    loaded = series(jobs, lag, start, load_end)
    a = slope(loaded, rate, duration)
    b = acceptance(sent, rate, duration, dropped)
    zeroed = zero_after(series(jobs, lag, load_end, capture_end))
    return {
        "sustained": a.ok and b.ok and zero_ok(zeroed),
        "a_backlog_slope": {"ok": a.ok, "slope_per_second": a.slope, "upper_95": a.upper, "limit": a.limit,
                            "samples": a.samples},
        "b_acceptance": {"ok": b.ok, "planned": b.planned, "sent": b.sent, "accepted": b.accepted,
                         "accepted_share": b.accepted_share, "dropped_iterations": b.dropped,
                         "dropped_share": b.dropped_share, "failed_share": b.failed_share},
        "c_zero_backlog": {"ok": zero_ok(zeroed), "seconds": zeroed, "limit_seconds": ZERO_LIMIT_SECONDS},
        "backlog_max": float(loaded["backlog"].max()),
        "backlog_end": float(loaded["backlog"].iloc[-1]),
    }
