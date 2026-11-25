# Experimento de carga e falhas

Mede as hipóteses de volume e robustez do Cloudesk (H1 a H7), com carga do k6 nas entradas de WhatsApp e chat, falhas de processo injetadas, reconciliação mensagem a mensagem e análise em pandas e Plotly. As hipóteses, o método e os resultados estão em `documents/fases/18-experimento-tecnico.md`.

A medida do dimensionamento (`scale/`) é outro roteiro, com o próprio `README.md`.

## Hipóteses na média (H5 a H7)

H1 a H4 têm o alvo de 250 msg/s e são as hipóteses originais. H5, H6 e H7 são acrescentadas em 25/11/2026 (UTC), depois do ensaio e dos pilotos, que medem 5, 24, 40 e 80 msg/s, e antes da primeira execução do degrau de 8 msg/s. São, portanto, informadas pelos pilotos. A carga é a média em horário comercial do volume de referência (`documents/arquitetura.md`), e os limites são os mesmos de H1, H2 e H4:

| # | Hipótese | Critério |
| - | - | - |
| H5 | A 8 msg/s por 3 min, a plataforma sustenta a carga | O mesmo da H1 |
| H6 | Nessa carga, p95 entrada → Kafka abaixo de 300 ms | O mesmo da H2 |
| H7 | Nessa carga, p95 ponta a ponta abaixo de 1 s | O mesmo da H4 |

O veredito vem da última execução medida da etapa `escada-8`, e todas as execuções são listadas. A duração é de 3 min, não de 15.

## Pré-requisitos

- Docker com pelo menos 5 GiB de memória disponível e o `.env` da raiz preenchido.
- Bash no host, com `curl` e `awk` (o Git Bash serve no Windows). Nenhum Python ou k6 no host.
- O projeto Compose `cloudesk` parado (`docker compose stop`). O experimento usa o projeto `cloudesk-experiment`, com rede e volumes próprios, e não toca nos volumes do `cloudesk`. Os serviços Rails e o Broker rodam o código copiado na imagem, sem a pasta `core/` montada do host; o id da imagem fica em `conditions.json`.
- Imagens construídas: `docker compose build` (o `preflight` reconstrói a do Core com o código atual) e `docker compose -p cloudesk-experiment -f compose.yaml -f experiment/compose.yaml --profile experiment build analysis`.

O `preflight` confere tudo isso, as portas e os contêineres de outros projetos. O notebook fica na tomada, sem suspensão por inatividade, e os programas pesados, fechados.

## Comandos

Da raiz do repositório, nesta ordem:

| Comando | O que roda | Tempo estimado |
| - | - | - |
| `experiment/run.sh preflight` | Confere a máquina e cria a sessão | 1 min |
| `experiment/run.sh ensaio` | 1 min a 5 msg/s, com a estrutura inteira | 5 a 10 min |
| `experiment/run.sh piloto [taxa] [papel=n ...]` | Uma rodada de 3 min (padrão 80 msg/s), com a tabela das rodadas no fim | 8 min por rodada |
| `experiment/run.sh h3` | 8 min à taxa do piloto, com as falhas e a `robustness:check` | 20 min |
| `experiment/run.sh escada` | 8 e 24 msg/s por 3 min e 80 por 5 min | 20 a 25 min |
| `experiment/run.sh meta` | 250 msg/s por até 15 min, no ambiente da escada; a partir do minuto 5, para se a H1 já falhou | 10 a 20 min |
| `experiment/run.sh meta sem-guarda-de-erros` | O mesmo degrau, em ambiente novo com 500 lojistas aquecidos e sem a guarda de erros | 15 a 25 min |
| `experiment/run.sh extra` | Só se 250 não foi sustentado: 160 por 5 min se 80 passou, 40 se não | 10 min |
| `experiment/run.sh email [semente]` | 10 e-mails a 1 por segundo, no último ambiente | 5 min |
| `experiment/run.sh relatorio` | Resumo e figuras da sessão | 2 min |
| `experiment/run.sh parar` | Remove os contêineres do projeto | 1 min |

Cada etapa recria o ambiente quando o plano dela pede ambiente novo: apaga os volumes do `cloudesk-experiment`, migra, roda as seeds, sobe os papéis com as réplicas de `replicas.env` e faz o aquecimento. `docker compose up -d` religa o projeto `cloudesk` no fim.

**Ajuste do piloto.** A rodada que não sustenta é repetida com um papel a mais por vez, por exemplo `experiment/run.sh piloto 80 jobs-default=3`: fila `webhooks` crescendo, `jobs-webhooks`; fila `channels`, `jobs-default`; lag de `cloudesk-agent`, `agent-mock` ou `web`, conforme o salto `kafka_to_agent` ou `agent`; lag de `cloudesk-broker`, `broker-consumer`; CPU total acima de 90% sem fila isolada, menos réplicas do papel mais ocioso. Depois de dois ajustes, a taxa cai para 40 e 24 msg/s com a configuração escolhida. Teto: `web=6`, `jobs-webhooks=4`, `jobs-default=4` e 3 nos demais. As réplicas e a taxa da H3 ficam em `replicas.env`.

**Guardas.** A etapa é interrompida com menos de 500 MB disponíveis no Docker em duas amostras seguidas, ou com mais de 20% de respostas diferentes de 200 no último minuto. O `meta sem-guarda-de-erros` desliga só a guarda de respostas, para o degrau de 250 chegar à conferência do minuto 5; a de memória vale, e `error_guard` fica em `conditions.json`. A etapa interrompida mantém os dados e não conta como medida.

**Espera do host.** No Windows, `conditions.json` registra as entradas e saídas da espera moderna (eventos 506 e 507 do Kernel-Power), e a etapa com a máquina em espera durante a carga é inválida. A suspensão e o desligamento da tela por inatividade ficam desligados durante as etapas.

## YJIT

Os processos Ruby rodam com o YJIT desligado. `EXPERIMENT_YJIT=1` liga o YJIT nos serviços Rails e do Broker, e o valor fica em `conditions.json` (`RUBY_YJIT_ENABLE`).

## Refazer uma etapa

Qualquer etapa pode ser repetida com o mesmo comando. Cada execução grava a pasta `<etapa>-<n>`, com `<n>` crescente, e nenhuma é apagada. `experiment/run.sh analisar <execução>` refaz só a análise sobre os dados brutos. `SESSION=<id>` escolhe outra sessão. O relatório lista todas as execuções, e as hipóteses e os critérios são os mesmos em todas.

## Resultados

```text
experiment/results/<sessão>/
  summary.json                     veredito e números por hipótese
  figures/*.png                    p95 por degrau
  replicas.env                     réplicas em uso e taxa da H3
  <etapa>-<n>/conditions.json      condições da execução
  <etapa>-<n>/summary.json         resultado da etapa
  <etapa>-<n>/faults.json          horários das falhas (H3)
  <etapa>-<n>/robustness.json      saída da robustness:check (H3 e e-mail)
  <etapa>-<n>/h1-check.json        conferência do minuto 5 (degrau de 250)
  <etapa>-<n>/figures/*.png        backlog, saltos, CPU e reconciliação
  <etapa>-<n>/raw/                 dados brutos, fora do Git
```

## Testes

```bash
docker compose -p cloudesk-experiment -f compose.yaml -f experiment/compose.yaml --profile experiment run --rm --no-deps analysis pytest
docker compose -p cloudesk-experiment -f compose.yaml -f experiment/compose.yaml --profile experiment run --rm --no-deps k6 run --iterations 1 /scripts/lanes_test.js
```

No Git Bash, os comandos com caminho de contêiner pedem `MSYS_NO_PATHCONV=1`.
