# Imagem do kit de conformidade do agente. No Compose, a pasta agent_conformance/ é montada em /app;
# a instalação editável aponta para /app/src e enxerga o código montado.
FROM python:3.13-slim

WORKDIR /app

COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir -e ".[test]"

CMD ["pytest"]
