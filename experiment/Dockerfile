# Imagem da análise do experimento. No Compose, a pasta experiment/ é montada em /app; a instalação
# editável aponta para /app/src e enxerga o código montado. O chromium e as fontes são do kaleido,
# que gera os PNG do Plotly.
FROM python:3.13-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y chromium fonts-dejavu-core && \
    rm -rf /var/lib/apt/lists/*

ENV BROWSER_PATH=/usr/bin/chromium

WORKDIR /app

COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir -e ".[test]"

CMD ["pytest"]
