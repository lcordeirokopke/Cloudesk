# Cloudesk · Simulador de canais

## O que é

O simulador de canais faz o papel de tudo o que fica do lado de fora do Cloudesk nos três canais de atendimento:

- **o lojista**, que escreve por WhatsApp, pelo chat do app ou por e-mail;
- **os provedores dos canais**: a Meta, que entrega o webhook do WhatsApp e recebe as respostas pela Cloud API; o app, que envia a mensagem do chat e recebe as respostas em tempo real; e o cliente de e-mail, que envia pelo SMTP e lê a caixa de entrada.

Ele envia ao Core mensagens sintéticas no formato real de cada canal, recebe as respostas que o Core entrega e registra o que enviou e o que recebeu. Com isso, o Cloudesk roda de ponta a ponta sem nenhuma integração externa e sem nenhum dado real.

## Onde fica no fluxo

```text
                 ┌──────────────────── channel-simulator ────────────────────┐
                 │  send / scenario                          serve           │
                 │  (lojista)                         (provedores, recepção) │
                 └────┬───────────────┬──────────────────────▲───────▲───▲───┘
   WhatsApp: POST assinado            │                      │       │   │
                      │       chat: POST assinado            │       │   │
                      │               │      e-mail: SMTP    │       │   │
                      ▼               ▼          │           │       │   │
              Core: /channels/whatsapp/webhook   ▼           │       │   │
                    /channels/chat/messages    Mailpit ──────┼───────┼───┘ poller da API
                      │                                      │       │
                      └── Intake → ... → Channels::DeliveryJob       │
                                     ├─ WhatsApp: POST /v1/<id>/messages
                                     └─ chat: Turbo Stream no Action Cable
```

O simulador roda como o serviço `channel-simulator` do Compose. O processo `serve` fica de pé com os receptores; os comandos que geram tráfego rodam no mesmo contêiner, com `docker compose exec`.

## Por que existe e que valor gera

**O sistema completo sem integrações reais.** O enunciado exclui sistemas de produção e dados reais. O simulador ocupa o lugar da Meta, do app e do cliente de e-mail com os formatos e as assinaturas que esses provedores usam, e o Core trata as mensagens dele exatamente como trataria as reais: o mesmo webhook, a mesma assinatura, o mesmo caminho de entrada e de saída.

**Recebimento multicanal demonstrável.** Um comando envia mensagens pelos três canais, das duas marcas, com texto, imagem ou documento, e outro mostra o mesmo lojista escrevendo por WhatsApp, chat e e-mail. A plataforma pode ser demonstrada e testada sem nenhum celular, navegador ou cliente de e-mail.

**Respostas verificáveis.** O simulador não só envia: ele recebe as respostas do Core em cada canal e as registra com o id da mensagem do Core. Uma resposta que chegou duas vezes aparece como o mesmo id repetido. Esse registro é a base da reconciliação da hipótese H3 (nenhuma mensagem perdida nem duplicada).

**Tráfego reproduzível.** Marca, canal, lojista, intenção, urgência, texto e anexo vêm de uma semente: a mesma semente gera o mesmo tráfego. Os ids externos são novos a cada execução, e uma execução repetida não vira reenvio para o Core.

**Dados sintéticos de ponta a ponta.** Os lojistas vêm das seeds, geradas com Faker, ou são criados na hora com identidades aleatórias. Os textos são modelos fixos, e os ids de transação, valores, datas e números de série são gerados. Nenhum dado real entra no sistema (LGPD).

## Como funciona

### Lojistas e canais das marcas

A task `bin/rails simulator:personas`, no Core, exporta para `core/tmp/simulator/personas.json` os lojistas das seeds com as três identidades (WhatsApp, e-mail e chat) e os canais de cada marca: os números de WhatsApp e os e-mails de suporte.

```json
{
  "brands": [
    {
      "slug": "infinitepay",
      "locale": "pt-BR",
      "whatsapp_numbers": [ { "phone_number_id": "110000000000001", "display": "551140000001" } ],
      "support_emails": [ "financeiro@infinitepay.test", "suporte@infinitepay.test" ],
      "contacts": [ { "name": "…", "whatsapp": "+55…", "email": "…@example.com", "chat": "app-…" } ]
    }
  ]
}
```

- A task roda com o papel da aplicação e lê os lojistas marca por marca, dentro do RLS. Só entram os lojistas com as três identidades (WhatsApp, e-mail e chat). A ordem é fixa e o arquivo não tem horário de geração: o mesmo banco gera sempre o mesmo arquivo.
- No Compose, a pasta é montada só leitura no simulador, que lê o arquivo a cada comando. O `serve` não depende dele.
- Com `contacts` igual a `new`, o simulador cria lojistas novos: nome de listas fixas por idioma, telefone com o código do país da marca (`+55` ou `+1`), e-mail `sim.<token>@example.com` e id do app `app-sim-<token>`. O Core cria o lojista na primeira mensagem.
- Os e-mails dos lojistas das seeds são ASCII. O `formataddr` do Python recusa endereço com acento na parte local, que exigiria SMTPUTF8 do simulador ao Mailpit e ao Action Mailbox.

### Conteúdo das mensagens

| Item | Como é gerado |
| - | - |
| Intenções | `transacao`, `repasse`, `taxas`, `maquininha`, `app` e `saudacao`, com três modelos cada em `pt-BR` e `en-US`, e um assunto de e-mail por intenção. A intenção é sorteada com peso: 25% `transacao`, 20% `repasse`, 15% `taxas`, 15% `maquininha`, 15% `app` e 10% `saudacao` |
| Urgência | Numa fração configurável das mensagens, o texto termina com uma frase de urgência por idioma (por exemplo "É urgente!" e "This is urgent!"), que leva o classificador à urgência `high` sem mudar a categoria |
| Campos | Id de transação (`TX` e 10 dígitos), valor no formato do idioma, data até 30 dias antes de uma data de referência fixa e número de série da maquininha (`SN` e 8 dígitos) |
| Anexos | `image` (`comprovante.jpg`) e `document` (`extrato.pdf`), numa fração configurável das mensagens. O e-mail leva os bytes gerados; WhatsApp e chat levam os metadados |
| Ids externos | `wamid.<uuid>` no WhatsApp, `client_message_id` no chat e `Message-ID` `<uuid@simulator.cloudesk.test>` no e-mail, novos a cada envio |

Os modelos, as frases de urgência e os assuntos de e-mail fazem parte do corpus do classificador do roteamento (`documents/fases/07-triagem-roteamento-e-distribuicao.md`): cada intenção cai na categoria esperada, a saudação fica sem categoria, e a frase de urgência leva a `high`.

### Envio

| Canal | Como o simulador envia |
| - | - |
| WhatsApp | `POST {CORE_URL}/channels/whatsapp/webhook` com o payload da Cloud API (`whatsapp_business_account`, `entry[].changes[].value` com `metadata`, `contacts` e `messages`), uma mensagem por chamada, tipos `text`, `image` e `document`. O corpo é serializado uma vez e assinado em `X-Hub-Signature-256` com `WHATSAPP_APP_SECRET`, como a Meta faz. O número da marca é sorteado entre os dela |
| Chat | `POST {CORE_URL}/channels/chat/messages` com `brand`, `app_user_id`, `client_message_id`, `text` e `attachments`, assinado com `CHAT_SIGNING_SECRET` no esquema HMAC com timestamp do contrato. A resposta traz `conversation_id`, `sequence` e o `stream` do lojista, que o comando registra no `serve` para receber as respostas |
| E-mail | SMTP ao Mailpit, com From do lojista, To de um e-mail de suporte da marca, assunto do modelo, corpo em texto e anexo opcional. O Mailpit avisa o Core, que lê o e-mail pelo Action Mailbox |

O comando `verify-whatsapp` faz o handshake `GET` do webhook do WhatsApp com `WHATSAPP_VERIFY_TOKEN`, como a Meta faz ao configurar o webhook; o sucesso é 200 com o próprio `challenge`.

O `send` agenda cada mensagem no instante `início + i / rate` e envia de forma concorrente: uma resposta lenta do Core não atrasa as seguintes, e a taxa pedida é mantida. Uma falha de montagem ou de envio vira um registro com o erro, e o comando segue com as demais mensagens.

### Recepção (`serve`)

O `serve` é um app `aiohttp` na porta 8080 com três receptores.

**WhatsApp.** O Core envia as respostas a `WHATSAPP_API_URL`, que aponta para o simulador (`http://channel-simulator:8080/v1`). O receptor atende `POST /{versão}/{phone_number_id}/messages`, como a Cloud API:

- sem o Bearer certo (`WHATSAPP_ACCESS_TOKEN`), responde 401;
- sem `messaging_product: "whatsapp"`, `to` ou `text.body`, responde 400 com o erro no formato da Meta;
- válido, registra a resposta e responde 200 no formato da Meta, com um `wamid` novo.

**Chat.** O simulador se conecta ao Action Cable do Core em `CORE_CABLE_URL` (`ws://web-lb:3000/cable` no Compose, pelo balanceador) como o widget de um navegador, com o header `Origin` igual a `CORE_ORIGIN` (`http://web-lb:3000`), e se inscreve no `Turbo::StreamsChannel` de cada stream registrado. Cada resposta chega como um `<turbo-stream action="append">` com o HTML da mensagem, do qual o simulador lê o id, a sequência, o canal, o autor e o texto; as mensagens com autor diferente do lojista são registradas.

- A conexão que cai é refeita com backoff exponencial, de 0,5 s dobrando até 30 s, e todos os streams são inscritos de novo.
- A conexão sem `welcome` ou sem nenhum frame por 6 s é dada como parada e refeita. O Core envia `ping` a cada 3 s, e o cliente JavaScript oficial do Action Cable usa o mesmo limite de 6 s.
- Uma falha ao enviar uma inscrição fecha a conexão, e a reconexão inscreve todos os streams.

Os streams são registrados em `POST /chat/streams`, com `stream` e `app_user_id` obrigatórios. O par novo ou repetido responde 200; o mesmo stream com outro `app_user_id` responde 409 e mantém o par original. Como o stream do Core é por lojista, o 409 deixa visível um erro de quem registrou. Os pares ficam em `data/streams.jsonl` e são relidos na partida do `serve`.

**E-mail.** A cada 2 s, um poller consulta a API do Mailpit pelas mensagens com a tag `cloudesk-ignored`, que o Core grava nas respostas que ele mesmo envia. Para cada mensagem nova, lê os headers e, com `X-Cloudesk-Message-Id`, registra a resposta. Os headers são decodificados da RFC 2047 (`=?UTF-8?Q?Re:_Repasse_n=C3=A3o_recebido?=` vira `Re: Repasse não recebido`). Os ids já vistos ficam em `data/mailpit_seen.jsonl`, e com o Mailpit fora do ar o ciclo registra o erro e tenta de novo no seguinte. O simulador não grava tags no Mailpit: a API substitui todas as tags de uma mensagem e não tem rota para acrescentar uma.

### Registro

Cada linha é um objeto JSON, gravado com append e `flush`, em `channel_simulator/data/`, fora do Git.

| Arquivo | Conteúdo |
| - | - |
| `runs/<run_id>/sent.jsonl` | Uma linha por envio: execução, canal, marca, origem do lojista (`seed` ou `new`), identidade, `external_id`, intenção, urgência (`urgent`), anexo, horário, status (HTTP, ou 250 no SMTP) e duração; no chat, `conversation_id`, `sequence` e o status do registro do stream; `error` quando a montagem ou o envio falha |
| `received.jsonl` | Uma linha por resposta recebida: canal, `core_message_id` (o id da `Message` do Core), destinatário, remetente e horário; no WhatsApp, texto e `traceparent`; no chat, stream, autor, texto e sequência, com o `app_user_id` do stream como destinatário e remetente nulo; no e-mail, assunto e id do Mailpit |
| `streams.jsonl` | Streams do chat registrados |
| `mailpit_seen.jsonl` | Ids do Mailpit já tratados |

O `run_id` é o horário UTC da execução e quatro caracteres aleatórios (`20261119T171041Z-1kr1`).

**Como os registros servem à reconciliação.** Um `core_message_id` repetido em `received.jsonl` é uma resposta entregue duas vezes ao lojista. O `external_id` de cada envio em `sent.jsonl` é o mesmo que o Core grava em `messages.external_id`, e com ele cada mensagem enviada é localizada no banco e na auditoria. A mensagem perdida é a mensagem do lojista sem ação aceita que a cubra, medida em `audit_events`.

### Comandos

Rodados no contêiner com `docker compose exec channel-simulator channel-simulator <comando>`:

| Comando | Opções | Efeito |
| - | - | - |
| `serve` | nenhuma | Sobe os receptores; é o comando padrão da imagem |
| `send` | `channel` (`whatsapp`, `chat`, `email` ou `all`), `brand` (`infinitepay`, `jim` ou `all`), `count`, `rate` (msg/s), `contacts` (`seed` ou `new`), `attachments` (fração de 0 a 1), `urgency-ratio` (fração de 0 a 1 com frase de urgência), `seed` | Envia `count` mensagens na taxa pedida, grava `sent.jsonl` e imprime o resumo por canal e status |
| `scenario cross-channel` | `brand`, `seed` | Um lojista das seeds escreve por WhatsApp, chat e e-mail, nessa ordem, e o comando imprime o `conversation_id` |
| `scenario <cenário de demonstração>` | `brand`, `seed`; `continue` (só no `memory`) | Lojista novo, passos com textos fixos, conferência no canal e impressão do `demo:check`; termina com código 1 quando uma expectativa no canal falha |
| `verify-whatsapp` | nenhuma | Handshake `GET` do webhook do WhatsApp |

### Cenários de demonstração

Cada cenário cria um lojista novo (`personas.new_contact`, com a semente e o `run_id`, então cada execução tem lojista próprio), envia os passos pelo canal do cenário com textos fixos no locale da marca (pt-BR em `infinitepay`, en-US em `jim`) e acompanha `received.jsonl`, filtrando pelo destinatário do lojista. Cada expectativa no canal imprime uma linha `ok` ou `falhou`: o trecho esperado em cada resposta, na ordem, ou nenhuma resposta durante o silêncio do passo. No fim, o comando imprime o `bin/rails demo:check` com `SCENARIO`, `BRAND`, `CHANNEL` e `EXTERNAL_IDS`, que confere no Core o que o lojista não vê (`core/lib/tasks/demo.rake`, só leitura). Os cenários exigem o `serve` de pé e rodam com `docker compose exec`, como o `cross-channel`.

| Cenário | Canal | Passos | No canal | No Core (`demo:check`) |
| - | - | - | - | - |
| `reply` | whatsapp | pergunta de taxas | resposta com as taxas da marca | conversa `with_ai`; um `agent.reply`; `message.delivered` |
| `handoff` | chat | mensagem sem intenção | nenhuma resposta em 10 s | `awaiting_human` na fila de escalação da fila de origem (ou na mesma, sem ela); `Handoff` `intencao_nao_identificada` com confiança 0,2 e a explicação em `attempts`; `conversation.escalated` |
| `reopen` | chat | taxas; agradecimento; taxas | taxas; nada em 5 s; taxas sem prefixo da memória | a conversa tem `conversation.resolved` e depois `conversation.reopened`; `with_ai`; dois `agent.reply` |
| `memory`, parte 1 | chat | taxas; agradecimento | taxas; nada em 5 s | imprime o `memory:demo_close` da conversa e o comando da parte 2 |
| `memory`, parte 2 | chat | taxas, com o mesmo lojista | taxas, começando com o prefixo da memória | duas conversas do lojista, a primeira `closed` e a segunda `with_ai`; `customer_memory`; `agent.reply` da segunda com o prefixo |
| `failure-duplicate` | chat | saudação com `[falha:duplicate]` | uma resposta e nada em 10 s | um `agent.reply`; uma linha em `processed_events` para a chave |
| `failure-stale` | chat | saudação; saudação com `[falha:stale]` | boas-vindas; mensagem de espera; nada em 50 s | SLA de 1 min; `agent.action.stale`; `conversation.escalated` `ai_timeout`; `awaiting_human` |
| `failure-drop` | chat | saudação com `[falha:drop]` | mensagem de espera; nada em 50 s | SLA de 1 min; nenhum evento de ação do agente; mensagem `system` `ai_timeout_wait`; `conversation.escalated` `ai_timeout` |
| `failure-delay` | chat | saudação com `[falha:delay=50000]` | mensagem de espera; boas-vindas | SLA de 1 min; espera antes do `agent.reply`; `with_ai`; nenhum `conversation.escalated` |

No `handoff`, o lojista não recebe mensagem; o trabalho do analista no painel é manual. O `memory` tem duas partes: a parte 1 imprime `docker compose exec web bin/rails memory:demo_close CONVERSATION=<id>` com o `conversation_id` devolvido pelo chat e o comando da parte 2, `scenario memory --continue <run_id>`, que lê o lojista em `runs/<run_id>/scenario.json`; o `demo:check` impresso pela parte 2 leva os `EXTERNAL_IDS` das duas partes. A troca de canal fica no `cross-channel`, com lojista das seeds, porque cada lojista novo tem uma identidade por canal.

Os cenários `failure-stale`, `failure-drop` e `failure-delay` dependem da varredura do timeout: as saudações não têm categoria no Core e caem na regra genérica, que precisa do SLA de 1 min. Com esse SLA, a espera sai entre 30 e 45 s (a varredura roda a cada 15 s) e a escalação entre 60 e 75 s; no `failure-delay`, o `reply` sai em cerca de 51 s, antes da escalação. Quando a espera não chega em 100 s, o comando lembra o `panel:demo_sla`, e o `demo:check` confere o SLA da conversa.

```text
docker compose exec web bin/rails panel:demo_sla BRAND=infinitepay MINUTES=1
docker compose exec channel-simulator channel-simulator scenario failure-drop --brand infinitepay
docker compose exec web bin/rails demo:check SCENARIO=failure-drop BRAND=infinitepay CHANNEL=chat EXTERNAL_IDS=<id>
docker compose exec web bin/rails panel:demo_sla_reset BRAND=infinitepay
```

Cada execução grava `runs/<run_id>/sent.jsonl` e `runs/<run_id>/scenario.json` (cenário, parte, marca, canal, lojista, ids externos, `conversation_id` devolvidos pelo chat e a execução continuada).

## O que o sistema garante

- Toda mensagem enviada usa o formato e a assinatura do canal real, e o Core a trata pelo mesmo caminho de uma mensagem real.
- Toda mensagem enviada fica em `sent.jsonl`, inclusive as que falharam, com o status e o erro.
- Toda resposta recebida fica em `received.jsonl` com o id da mensagem do Core, e uma entrega repetida aparece como id repetido.
- A mesma semente gera o mesmo tráfego, com ids externos novos.
- O receptor do chat se recupera sozinho de queda e de conexão parada, e o do e-mail de queda do Mailpit, sem perder o que já registrou.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Recebimento multicanal simulado: chat, WhatsApp (Cloud API) e e-mail (Mailpit) | O lado de fora dos três canais: o lojista que escreve e o provedor que recebe as respostas | Entradas, identidade e saída de cada canal no Core (F4) |
| Interface de conversa entre cliente e atendente | O cliente de cada canal, que recebe as respostas da IA e do analista como o lojista as receberia | Widget de chat e telas (F4 e F11) |
| Memória e contexto entre canais | O cenário `cross-channel`, em que o mesmo lojista escreve pelos três canais e as mensagens caem na mesma conversa | Identidade unificada (F4) e memória do lojista (F12) |
| Dados sintéticos (LGPD) | Textos, ids, valores e lojistas novos gerados, e lojistas das seeds | Seeds com Faker (F1) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H3 · nenhuma mensagem perdida nem duplicada | O `received.jsonl` mostra as respostas duplicadas pelo id da mensagem do Core, e o `sent.jsonl` liga cada envio à mensagem gravada pelo `external_id` |
| H1, H2 e H4 | A carga vem do k6, direto nas entradas de WhatsApp e chat; o simulador é o destino das respostas. Sem ele, a entrega do WhatsApp não tem para onde ir e o chat não tem quem receba. O `POST /chat/streams` existe para que o k6 registre os streams do chat, com o `app_user_id` |

## Diferenciais

Nenhum diferencial é implementado aqui. O simulador é o que torna a demonstração deles possível sem integrações reais: as mensagens que ele envia são as que passam pelo roteamento explicado no "Por que caiu aqui?", pelo agente com os modos de falha e pelo handoff ao analista.

## Limitações

- **Respostas de chat durante a queda do WebSocket.** O Turbo Stream não reenvia o que foi transmitido enquanto o simulador estava desconectado. No experimento, o simulador fica de pé durante a carga, e as falhas da H3 atingem Broker e worker, não o simulador.
- **Conexão do Action Cable sem inscrições.** Existe um caso sem causa determinada em que o WebSocket fica aberto sem nenhuma inscrição enviada, e as respostas de chat não são registradas; o processo reiniciado se inscreve normalmente. O monitor de conexão parada e o fechamento na falha de inscrição cobrem `welcome` perdido, conexão sem ping e erro de envio, e os logs de conexão e de inscrição identificam o caso. Antes da carga, a confirmação de cada stream é conferida no log do `web` (`Turbo::StreamsChannel is transmitting the subscription confirmation`).
- **E-mail fora da carga.** O poller do Mailpit atende o teste funcional, não 250 msg/s. O e-mail fica fora da carga do experimento, como prevê a arquitetura.
- **Personas atualizadas à mão.** Se as seeds mudam, a task `simulator:personas` precisa rodar de novo antes dos comandos.
- **Lojistas já gravados.** As seeds buscam o lojista pelo telefone e não alteram um lojista existente: um e-mail gravado com acento continua assim até que a identidade seja atualizada.
- **Textos fixos.** São três modelos por intenção e idioma, sem variação de escrita, erros de digitação ou mensagens longas. Exercitam o caminho, não a qualidade do classificador.
- **Sem modos de falha no receptor.** O receptor do WhatsApp sempre aceita uma resposta válida; ele não simula indisponibilidade da Meta.
- **Sem Python na máquina.** O simulador e seus testes rodam no contêiner.

## Operação

### Configuração

Serviço `channel-simulator` no `compose.yaml`, imagem `cloudesk-channel-simulator:dev` (`python:3.13-slim`, dependência `aiohttp`), porta 8080, com `./channel_simulator` em `/app`, `./contracts` em `/contracts` e `./core/tmp/simulator` em `/personas`, os dois últimos só leitura.

| Variável | Uso |
| - | - |
| `CORE_URL` | Base das entradas do Core (`http://web-lb:3000` no Compose; padrão do código `http://web:3000`) |
| `CORE_CABLE_URL`, `CORE_ORIGIN` | WebSocket do Action Cable e header `Origin` |
| `MAILPIT_API_URL` | API do Mailpit, para o poller |
| `SMTP_HOST`, `SMTP_PORT` | SMTP do Mailpit, para o envio |
| `WHATSAPP_APP_SECRET` | Assinatura `X-Hub-Signature-256` da entrada |
| `WHATSAPP_VERIFY_TOKEN` | Handshake `GET` do webhook |
| `WHATSAPP_ACCESS_TOKEN` | Bearer conferido no receptor |
| `CHAT_SIGNING_SECRET` | Assinatura da entrada do chat |
| `CONTRACTS_PATH` | Vetores de assinatura nos testes |
| `PERSONAS_PATH` | Arquivo exportado pela task |
| `SIMULATOR_DATA_DIR` | Pasta dos registros |
| `SIMULATOR_PORT` | Porta do `serve` |
| `MAILPIT_POLL_SECONDS` | Intervalo do poller |

No Core, `WHATSAPP_API_URL` é `http://channel-simulator:8080/v1`.

**Ordem de uso:** seeds; `docker compose exec web bin/rails simulator:personas`; `docker compose up -d channel-simulator`.

### Arquivos principais

| Arquivo | Conteúdo |
| - | - |
| `channel_simulator/src/channel_simulator/cli.py` | Comandos |
| `channel_simulator/src/channel_simulator/sender.py` | Envio com taxa controlada e cenário entre canais |
| `channel_simulator/src/channel_simulator/scenarios.py` | Cenários de demonstração: textos por locale, respostas esperadas e executor com a conferência no canal |
| `core/lib/tasks/demo.rake` | Task `demo:check`, conferência dos cenários de demonstração no Core |
| `channel_simulator/src/channel_simulator/whatsapp.py` | Payload da Cloud API, assinatura, envio, verificação e receptor |
| `channel_simulator/src/channel_simulator/chat.py` | Envio assinado, registro de streams, leitura do Turbo Stream e cliente Action Cable |
| `channel_simulator/src/channel_simulator/email.py` | Montagem do e-mail, envio SMTP e poller do Mailpit |
| `channel_simulator/src/channel_simulator/templates.py` | Modelos de texto por intenção e idioma, e anexos |
| `channel_simulator/src/channel_simulator/personas.py` | Leitura do `personas.json` e lojistas novos |
| `channel_simulator/src/channel_simulator/signature.py` | Assinatura HMAC com timestamp do contrato, a mesma implementação do agente mock |
| `channel_simulator/src/channel_simulator/server.py` | App do `serve`: rotas e tarefas de fundo |
| `core/lib/tasks/simulator.rake` | Task `simulator:personas` |

### Verificação

Os testes do simulador rodam no contêiner com `docker compose exec channel-simulator pytest`. Os servidores falsos (Core, Action Cable e Mailpit) são apps `aiohttp` de teste, e o SMTP falso é um `socketserver` em thread.

| Arquivo | O que comprova |
| - | - |
| `channel_simulator/tests/test_signature.py` | Vetores de assinatura do contrato |
| `channel_simulator/tests/test_personas.py` | Leitura do arquivo e lojistas novos determinísticos, com o código do país da marca |
| `channel_simulator/tests/test_records.py` | JSONL com append e `flush` |
| `channel_simulator/tests/test_templates.py` | Determinismo, idioma, modelos por intenção, sorteio com peso, frases de urgência e anexos |
| `channel_simulator/tests/test_whatsapp.py` | Payload de texto, imagem e documento; assinatura; verificação; receptor com Bearer certo, errado e ausente, corpo inválido e registro |
| `channel_simulator/tests/test_chat.py` | Envio assinado; registro de streams (200, 400, 409, persistido e relido); leitura do Turbo Stream; cliente Action Cable com welcome, inscrição, mensagem, reconexão, inscrição recusada, welcome ausente e conexão parada |
| `channel_simulator/tests/test_email.py` | Montagem com e sem anexo; envio SMTP com sucesso, destinatário recusado e servidor fora do ar; poller com paginação, header ausente, id já visto, ids relidos, headers RFC 2047 e Mailpit fora do ar |
| `channel_simulator/tests/test_sender.py` | Sorteio determinístico; `send` nos três canais; cenário entre canais; erro de montagem registrado; Core fora do ar |
| `channel_simulator/tests/test_server.py` | Rotas, `GET /health` e streams relidos na partida |
| `channel_simulator/tests/test_scenarios.py` | Textos e respostas nos dois locales; marcadores dos cenários de falha; executor com envio e `received.jsonl` simulados: expectativa cumprida, resposta faltando ou diferente, resposta a mais no silêncio, envio com erro, código de saída, `scenario.json`, lojista novo por execução, as duas partes do `memory` com `--continue` e o `demo:check` impresso com os `EXTERNAL_IDS` |
| `core/spec/tasks/demo_check_spec.rb` | Cada cenário montado com os serviços reais passa e, com uma expectativa quebrada, falha; mensagem não encontrada; cenário, canal e marca desconhecidos; aviso do SLA nos cenários de timeout; a task não grava nada |
| `core/spec/tasks/simulator_personas_spec.rb` | Marcas e canais, lojistas da própria marca com as três identidades, lojista incompleto fora e mesma saída em duas execuções |
| `core/spec/seeds_spec.rb` | E-mails dos lojistas em ASCII |

No Compose, com `web`, `jobs-default`, `mailpit` e `channel-simulator`: o `verify-whatsapp` responde 200 com o `challenge`; o `scenario cross-channel` grava três mensagens do mesmo lojista na mesma conversa; o `send` nos três canais e nas duas marcas grava uma mensagem por envio, com `message.created`, e o job de webhook para as conversas que ficaram com a IA; as respostas do Core chegam a `received.jsonl`, uma por canal, com o id da mensagem do Core; a mesma entrega repetida aparece como o mesmo `core_message_id` duas vezes; e, depois de um reinício do `channel-simulator`, os streams são inscritos de novo e os e-mails já vistos não são registrados outra vez. Com o `agent-mock` de pé, cada cenário de demonstração, nas duas marcas, termina com código 0 no simulador e no `demo:check` impresso (os de timeout com o `panel:demo_sla` de 1 min).

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco e seeds (F1) | Os lojistas e os canais das marcas vêm das seeds, pela task `simulator:personas` |
| Contrato (F3) | O simulador usa do contrato a assinatura HMAC com timestamp, na entrada do chat, e roda os mesmos vetores de teste |
| Canais (F4) | O simulador fala com as entradas e é o destino das saídas de cada canal |
| Roteamento (F6) | Os modelos de texto e os assuntos de e-mail fazem parte do corpus do classificador |
| API de ações (F8) | A resposta do agente sai por `Conversations::Outbound.append!` e chega ao simulador pelo canal de origem |
| Handoff e painel (F11) | A resposta do analista sai pelo mesmo caminho, e o registro do chat guarda o autor |
| Experimento (F18) | O k6 registra os streams do chat no simulador pelo `POST /chat/streams`; a reconciliação lê `sent.jsonl`, `received.jsonl` e `audit_events` |

## Fontes

- `documents/arquitetura.md`, seções "Componentes simulados" e "Experimento técnico"
- `documents/fases/05-canais-de-entrada-e-identidade.md`, formatos de entrada e de saída de cada canal
- Código da gem `actioncable` 8.1.4.1 na imagem `cloudesk-core:dev` (`server/connections.rb`: `BEAT_INTERVAL = 3`; `connection/base.rb`; `app/assets/javascripts/actioncable.js`: `ConnectionMonitor.staleThreshold = 6`)
- Código do `smtplib` na imagem `python:3.13-slim` (`sendmail`: `SMTPDataError` para resposta diferente de 250 ao `DATA`)
- [Mailpit · API v1](https://mailpit.axllent.org/docs/api-v1/)
- [Mailpit · Swagger da API](https://raw.githubusercontent.com/axllent/mailpit/master/server/ui/api/v1/swagger.json)
- [Mailpit · Search filters](https://mailpit.axllent.org/docs/usage/search-filters/)
- [Meta · WhatsApp Cloud API, exemplos de payload de webhook](https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples/)
- [Meta · WhatsApp Cloud API, referência de envio de mensagens](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages/)
