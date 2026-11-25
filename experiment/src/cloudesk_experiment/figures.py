"""Figuras em PNG da etapa e da sessão.

Paleta categórica em ordem fixa; a cor acompanha a série, não a posição. Cada gráfico tem um eixo Y
só, e grandezas diferentes ficam em painéis separados. Os textos usam tinta neutra.
"""

import math
from pathlib import Path

import pandas as pd
import plotly.graph_objects as go
import plotly.io as pio
from plotly.subplots import make_subplots

from . import backlog

BLUE, ORANGE, AQUA, YELLOW, MAGENTA = "#257de0", "#f47230", "#00b894", "#f2a600", "#ee7fac"
INK, MUTED, GRID = "#191919", "#666666", "#e6e6e6"
SERIES = {
    "webhooks": ("Fila webhooks", BLUE),
    "channels": ("Fila channels", ORANGE),
    "default": ("Fila default", AQUA),
    "cloudesk-agent": ("Lag cloudesk-agent", YELLOW),
    "cloudesk-broker": ("Lag cloudesk-broker", MAGENTA),
}
FONT = "DejaVu Sans"
WIDTH, HEIGHT, SCALE = 1100, 560, 2


def _layout(figure: go.Figure, title: str, subtitle: str = "", height: int = HEIGHT) -> go.Figure:
    text = f"<b>{title}</b>" + (f"<br><span style='font-size:13px;color:{MUTED}'>{subtitle}</span>" if subtitle else "")
    figure.update_layout(
        title={"text": text, "x": 0.01, "xanchor": "left", "y": 0.95, "yanchor": "top", "font": {"size": 18, "color": INK}},
        font={"family": FONT, "size": 13, "color": MUTED}, paper_bgcolor="#ffffff", plot_bgcolor="#ffffff",
        width=WIDTH, height=height, margin={"l": 80, "r": 40, "t": 110, "b": 70}, bargap=0.45,
        legend={"orientation": "h", "x": 0, "y": -0.16, "yanchor": "top"},
    )
    figure.update_xaxes(showgrid=False, linecolor=GRID, ticks="outside", tickcolor=GRID)
    figure.update_yaxes(gridcolor=GRID, zeroline=False, rangemode="tozero")
    return figure


def seconds_label(value: float | None) -> str:
    if value is None:
        return "sem medida"
    if math.isinf(value):
        return "sem resposta"
    return f"{value * 1000:.0f} ms" if value < 1 else f"{value:.1f} s".replace(".", ",")


def backlog_figure(frame: pd.DataFrame, title: str, subtitle: str, marks: list[tuple[float, str]] = ()) -> go.Figure:
    """Jobs e lag por tempo, em dois painéis; marks são instantes (s) com rótulo."""
    figure = make_subplots(rows=2, cols=1, shared_xaxes=True, vertical_spacing=0.1,
                           subplot_titles=("Jobs prontos e em execução", "Mensagens de lag no Kafka"))
    minutes = frame["elapsed"] / 60
    for row, names in ((1, backlog.QUEUES), (2, backlog.GROUPS)):
        for name in names:
            label, color = SERIES[name]
            figure.add_trace(go.Scatter(x=minutes, y=frame[name], name=label, mode="lines",
                                        line={"color": color, "width": 2}), row=row, col=1)
    for second, label in marks:
        for row in (1, 2):
            figure.add_vline(x=second / 60, line={"color": MUTED, "width": 1, "dash": "dot"}, row=row, col=1)
        figure.add_annotation(x=second / 60, y=1, xref="x2", yref="paper", text=label, showarrow=False, textangle=-90,
                              xanchor="right", yanchor="top", font={"size": 11, "color": MUTED})
    _layout(figure, title, subtitle, height=680)
    figure.update_layout(legend={"y": -0.15}, margin={"b": 110})
    figure.update_xaxes(title_text="Minutos desde o início da carga", row=2, col=1)
    figure.update_annotations(font_color=MUTED)
    return figure


def p95_by_rate(rows: list[dict], key: str, limit: float, title: str, subtitle: str) -> go.Figure:
    """p95 (s) por degrau, em escala log, com a linha da meta. rows: run, rate e o valor em key."""
    labels = [f"{row['rate']:g} msg/s<br>{row['run']}" for row in rows]
    values = [row[key] for row in rows]
    finite = [value for value in values if value is not None and not math.isinf(value)]
    top = max([*finite, limit]) * 3
    plotted = [top if value is not None and math.isinf(value) else value for value in values]
    figure = go.Figure(go.Scatter(
        x=labels, y=plotted, mode="markers+text", text=[seconds_label(value) for value in values],
        textposition="top center", textfont={"color": INK, "size": 13}, marker={"color": BLUE, "size": 12},
        showlegend=False, cliponaxis=False))
    figure.add_hline(y=limit, line={"color": MUTED, "width": 1.5, "dash": "dash"})
    # No eixo log, a anotação usa o expoente.
    figure.add_annotation(x=1, xref="paper", xanchor="right", y=math.log10(limit), yref="y", yanchor="top",
                          text=f"meta: {seconds_label(limit)}", showarrow=False, font={"color": MUTED})
    _layout(figure, title, subtitle)
    lowest = min([*finite, limit])
    ticks = [tick for tick in (0.01, 0.03, 0.1, 0.3, 1, 3, 10, 30, 100, 300, 1000) if lowest / 3 <= tick <= top * 2]
    figure.update_yaxes(type="log", range=[math.log10(lowest / 2), math.log10(top * 1.5)], tickvals=ticks,
                        ticktext=[seconds_label(tick) for tick in ticks])
    return figure


def bars(names: list[str], values: list[float | None], title: str, subtitle: str, label) -> go.Figure:
    """Barras horizontais de uma série, com o valor na ponta."""
    figure = go.Figure(go.Bar(x=[value or 0 for value in values], y=names, orientation="h", marker={"color": BLUE, "cornerradius": 4},
                              text=[label(value) for value in values], textposition="outside",
                              textfont={"color": INK}, cliponaxis=False, showlegend=False))
    _layout(figure, title, subtitle, height=max(360, 150 + 40 * len(names)))
    figure.update_layout(margin={"l": 200, "r": 110})
    figure.update_yaxes(autorange="reversed", showgrid=False)
    figure.update_xaxes(showticklabels=False, showline=False, ticks="")
    return figure


def write(figures: dict[str, go.Figure], directory: Path) -> list[Path]:
    """Grava um PNG por figura, em um único processo do navegador."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    paths = [directory / f"{name}.png" for name in figures]
    if figures:
        pio.write_images(fig=list(figures.values()), file=paths, scale=SCALE, width=WIDTH,
                         height=[figure.layout.height for figure in figures.values()])
    return paths
