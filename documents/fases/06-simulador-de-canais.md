# Cloudesk · F5 · Simulador de canais

## Objetivo

O simulador de canais faz o papel do lojista e dos provedores dos três canais (Meta no WhatsApp, app no chat, cliente de e-mail). Ele envia mensagens sintéticas ao Core, recebe as respostas que o Core entrega a cada canal e registra o que enviou e o que recebeu, para a reconciliação de perdas e duplicações da F17.

Este documento detalha cada decisão e a fonte que a sustenta. O resumo está em `documents/arquitetura.md`, que prevalece; a lista de entregas e o critério de pronto estão em `contexto/ordem-de-implementacao.md`. Os formatos de entrada e de saída de cada canal são os de `documents/fases/05-canais-de-entrada-e-identidade.md`.

## Resumo das decisões

| # | Tema | Decisão |
| - | - | - |
| 1 | Escopo | Uma versão só, completa: envio, recepção e registro. A recepção é testada com respostas gravadas por `Conversations::Outbound.append!`; Broker, agente e API de ações ficam nas suas fases |
| 2 | Forma | Serviço `channel-simulator` no Compose, imagem própria. Processo longo `serve` com os três receptores; comandos de linha de comando para gerar tráfego, rodados com `docker compose exec` |
| 3 | Dependências | `aiohttp` (servidor HTTP, cliente HTTP e WebSocket); SMTP com `smtplib` da biblioteca padrão |
| 4 | Entrada WhatsApp | Payload da Cloud API no formato lido pela F4, uma mensagem por `POST`, id `wamid.<uuid>`, `X-Hub-Signature-256` com `WHATSAPP_APP_SECRET`; tipos `text`, `image` e `document` com legenda |
| 5 | Saída WhatsApp | `POST /{versão}/{phone_number_id}/messages`, qualquer segmento de versão; Bearer conferido com `WHATSAPP_ACCESS_TOKEN`; 200 no formato da Meta; `WHATSAPP_API_URL=http://channel-simulator:8080/v1` |
| 6 | Verificação `GET` | Comando `verify-whatsapp`, com `WHATSAPP_VERIFY_TOKEN` |
| 7 | Modos de falha no receptor | Não existem |
| 8 | Entrada chat | `POST /channels/chat/messages` assinado com `CHAT_SIGNING_SECRET`. A assinatura é tudo o que o simulador consome do contrato da F3 |
| 9 | Saída chat | WebSocket em `ws://web:3000/cable`, `Origin: http://web:3000`, sem configuração nova no Core; inscrição no `Turbo::StreamsChannel` com o `stream` devolvido pela entrada |
| 10 | Streams | Endpoint `POST /chat/streams` no simulador, com `stream` e `app_user_id` obrigatórios; usado pelo comando `send` e pelo k6 |
| 11 | Entrada e-mail | SMTP para `mailpit:1025`; From do lojista, To do e-mail de suporte, `Message-ID` `<uuid@simulator.cloudesk.test>`, anexo opcional |
| 12 | Saída e-mail | Polling da API do Mailpit pelas mensagens com a tag `cloudesk-ignored` e o header `X-Cloudesk-Message-Id`; deduplicação pelo ID do Mailpit, sem gravar tag |
| 13 | Personas | Task `bin/rails simulator:personas` exporta lojistas das seeds e canais das marcas para `core/tmp/simulator/personas.json`; o simulador monta a pasta só leitura. Opção de lojistas novos com identidades aleatórias |
| 14 | Texto | Modelos fixos por intenção (transação, repasse, taxas, maquininha, saudação), em `pt-BR` e `en-US`; campos sintéticos de `random.Random(seed)`; sem Faker no Python; fração configurável com anexo |
| 15 | Registro | JSONL em `channel_simulator/data/`, fora do Git. Duplicada é o mesmo id da `Message` do Core recebido duas vezes |
| 16 | Testes | pytest das partes do simulador; checagem ponta a ponta no Compose; sem teste cruzado em Ruby além dos vetores de assinatura |

## Arquivos

### Simulador (`channel_simulator/`)

| Arquivo | Conteúdo |
| - | - |
| `Dockerfile` | `python:3.13-slim`, instalação editável com o extra `test`; comando padrão `channel-simulator serve` |
| `pyproject.toml` | Dependência `aiohttp`; extra `test` com `pytest` e `pytest-aiohttp`; script `channel-simulator` |
| `src/channel_simulator/config.py` | Leitura do ambiente |
| `src/channel_simulator/signature.py` | Cópia de `agent_mock/src/agent_mock/signature.py` |
| `src/channel_simulator/personas.py` | Leitura do `personas.json`; lojistas novos |
| `src/channel_simulator/templates.py` | Modelos de texto por intenção e locale; anexos sintéticos |
| `src/channel_simulator/records.py` | Escrita JSONL com append e `flush` por linha |
| `src/channel_simulator/whatsapp.py` | Payload da Cloud API, assinatura, envio, verificação e receptor |
| `src/channel_simulator/chat.py` | Envio assinado, registro de streams, parser do Turbo Stream e cliente Action Cable |
| `src/channel_simulator/email.py` | Montagem do e-mail, envio SMTP e poller do Mailpit |
| `src/channel_simulator/server.py` | App `aiohttp` do `serve`: rotas e tarefas de fundo |
| `src/channel_simulator/sender.py` | Envio com taxa controlada e cenário entre canais |
| `src/channel_simulator/cli.py` | Comandos |
| `tests/` | Testes |
| `data/` | Registros, criado em tempo de execução, fora do Git |

### Core e raiz

| Arquivo | Conteúdo |
| - | - |
| `core/lib/tasks/simulator.rake` | Task `simulator:personas` |
| `core/spec/tasks/simulator_personas_spec.rb` | Teste da task |
| `core/db/seeds.rb` | E-mail do lojista em ASCII (ver "Personas") |
| `compose.yaml` | Serviço `channel-simulator` |
| `.env.example` | `WHATSAPP_API_URL=http://channel-simulator:8080/v1` |
| `.gitignore` | `channel_simulator/data/` |

## Personas

A task `simulator:personas` roda com o papel da aplicação. Para cada marca, em ordem de `slug`, lê os `BrandChannel` (fora do RLS) e, em `Tenancy.with_brand`, os `Contact` que têm as três identidades (`whatsapp`, `email` e `chat`), em ordem de `id`. O destino é `ENV["SIMULATOR_PERSONAS_PATH"]`, padrão `tmp/simulator/personas.json`.

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

- A ordem é fixa e o arquivo não tem horário de geração: duas execuções no mesmo banco geram o mesmo arquivo.
- No Compose, `core/tmp/simulator` é montada só leitura em `/personas`. O simulador lê o arquivo a cada comando; o `serve` não depende dele.
- **Lojistas novos** (`contacts` igual a `new`): nome de listas fixas por locale, telefone com o código do país da marca (`+55` em `pt-BR`, `+1` em `en-US`), e-mail `sim.<token>@example.com` e id do app `app-sim-<token>`, todos de `random.Random(seed)`. O Core cria o `Contact` na primeira mensagem.
- **E-mail em ASCII.** O e-mail dos lojistas das seeds passa por `I18n.transliterate` (`documents/fases/02-banco-multi-marca-e-entidades.md`, seção "Seeds"). O `formataddr` do Python recusa endereço com acento na parte local; esse endereço exigiria SMTPUTF8 do simulador ao Mailpit e ao Action Mailbox.

## Conteúdo das mensagens

- Intenções `transacao`, `repasse`, `taxas`, `maquininha` e `saudacao`, com três modelos cada em `pt-BR` e `en-US`, e um assunto de e-mail por intenção.
- Campos sintéticos: id de transação (`TX` e 10 dígitos), valor (formato do locale), data (até 30 dias antes de uma data de referência fixa) e número de série da maquininha (`SN` e 8 dígitos).
- Anexos: `image` (`comprovante.jpg`, `image/jpeg`) e `document` (`extrato.pdf`, `application/pdf`), com bytes gerados. O e-mail leva os bytes; o WhatsApp e o chat levam só os metadados.
- A semente define marca, canal, lojista, intenção, texto e anexo. Os ids externos (`wamid`, `Message-ID`, `client_message_id`) vêm de `uuid4` e são únicos a cada execução: o mesmo id é reenvio para o Core.

## Envio

### WhatsApp

- Payload da Cloud API: `object: "whatsapp_business_account"`, `entry[].changes[]` com `field: "messages"` e `value` com `messaging_product`, `metadata` (`display_phone_number`, `phone_number_id`), `contacts` (`profile.name`, `wa_id`) e `messages` (`from` sem `+`, `id`, `timestamp`, `type` e o objeto do tipo). `image` e `document` levam `mime_type` e `caption`; o documento leva também `filename`.
- O corpo é serializado uma vez, e `X-Hub-Signature-256` é `sha256=` seguido do HMAC-SHA256 hexadecimal desses bytes.
- `POST {CORE_URL}/channels/whatsapp/webhook`. O número da marca é sorteado entre os dois da marca.

### Chat

- Corpo `{ brand, app_user_id, client_message_id, text, attachments }`, assinado com `signature.headers(CHAT_SIGNING_SECRET, "POST", "/channels/chat/messages", corpo)`.
- A resposta 200 traz `conversation_id`, `sequence` e `stream`. O comando registra o par `stream` e `app_user_id` no `serve`, por `POST /chat/streams`.

### E-mail

- `EmailMessage` com From `"<nome>" <e-mail do lojista>`, To o e-mail de suporte, Subject do modelo, `Message-ID` `<uuid4@simulator.cloudesk.test>`, corpo `text/plain` e anexo opcional.
- `smtplib.SMTP(SMTP_HOST, SMTP_PORT).send_message`, em `asyncio.to_thread`.
- O `external_id` registrado é o `Message-ID` sem `<` e `>`, igual ao que o `SupportMailbox` grava.
- O status é 250 quando o envio termina sem exceção. No `smtplib` 3.13, `sendmail` lança `SMTPDataError` para qualquer resposta diferente de 250 ao `DATA`, e o destinatário único recusado vira `SMTPRecipientsRefused`. Em erro, o status é o código SMTP da exceção, quando ela traz um, ou o nome da exceção.

### Verificação do webhook

`verify-whatsapp` faz `GET {CORE_URL}/channels/whatsapp/webhook` com `hub.mode=subscribe`, `hub.verify_token` e um `hub.challenge` aleatório. Sucesso é 200 com o próprio `challenge`.

## Recepção (`serve`)

App `aiohttp` na porta `SIMULATOR_PORT` (8080):

| Rota | Função |
| - | - |
| `POST /{versão}/{phone_number_id}/messages` | Receptor do envio do WhatsApp |
| `POST /chat/streams` | Registro dos streams do chat |
| `GET /health` | Saúde do processo |

O cliente Action Cable e o poller do Mailpit rodam como tarefas de fundo do app.

### WhatsApp

- Sem `Authorization: Bearer <WHATSAPP_ACCESS_TOKEN>` correto: 401.
- Corpo sem `messaging_product: "whatsapp"`, `to` ou `text.body`: 400 com `{"error": {"message": "…"}}`.
- Válido: grava em `received.jsonl` e responde 200 com `{"messaging_product": "whatsapp", "contacts": [{"input": to, "wa_id": to}], "messages": [{"id": "wamid.<uuid>"}]}`.

### Registro de streams

- `POST /chat/streams` com `{"stream": "…", "app_user_id": "…"}`. Sem um dos dois: 400. Par novo ou o mesmo par de novo: 200. Stream já registrado com outro `app_user_id`: 409, mantendo o par original.
- O stream do Core é por lojista; o mesmo stream com outro `app_user_id` indica erro de quem chamou, e o 409 deixa a anomalia visível.
- Quem registra sempre conhece o `app_user_id`: acabou de enviar a mensagem com ele. Com o campo obrigatório, o `recipient` do chat nunca fica nulo, também na carga do k6.
- Os pares ficam em memória e em `data/streams.jsonl`, relido na partida do `serve`.

### Chat (Action Cable)

- Conecta em `CORE_CABLE_URL` com `Origin: CORE_ORIGIN` e o subprotocolo `actioncable-v1-json`.
- No `welcome`, envia `{"command": "subscribe", "identifier": "{\"channel\":\"Turbo::StreamsChannel\",\"signed_stream_name\":\"…\"}"}` para cada stream registrado. Um stream registrado com a conexão aberta é assinado na hora.
- Ignora `ping` e `confirm_subscription`; registra `reject_subscription` em log.
- Cada `message` é um `<turbo-stream action="append" target="messages">` com o partial `channels/chat/_message.html.erb`. O parser (`html.parser`) lê do `div` o `id` (`message_<uuid>`), `data-sequence`, `data-channel`, o autor (classe `chat-message-<autor>`) e o texto de `.chat-message__body`.
- As mensagens com autor diferente de `customer` vão a `received.jsonl`.
- **Reconexão:** na queda da conexão, reconecta com backoff exponencial (0,5 s, dobrando até 30 s) e assina de novo todos os streams.
- **Conexão parada:** sem `welcome` em 6 s depois de abrir, ou sem nenhum frame por 6 s, a conexão é fechada e refeita. O servidor envia `ping` a cada 3 s, e o cliente JS oficial usa o mesmo limite de 6 s.
- **Falha ao assinar:** uma falha no envio de uma assinatura fecha a conexão; a reconexão assina de novo todos os streams.
- Os logs registram cada conexão (quantos streams são assinados) e cada assinatura enviada.

**Origem do WebSocket.** Na gem `actioncable` 8.1.4.1, `ActionCable::Connection::Base` aceita a conexão quando `allow_same_origin_as_host` está ligado (padrão `true`) e o `Origin` é igual a `<protocolo>://<Host>`, ou quando o `Origin` casa com `allowed_request_origins`. O simulador conecta em `web:3000` com `Origin: http://web:3000`, igual ao Host, como um navegador com o widget aberto nesse endereço; `config.hosts` já inclui `web`.

### E-mail (poller do Mailpit)

A cada `MAILPIT_POLL_SECONDS`:

- `GET {MAILPIT_API_URL}/api/v1/search?query=tag:cloudesk-ignored&start=<n>&limit=50`, página a página, até uma página em que todos os IDs já foram vistos ou até o fim (`messages_count`);
- para cada ID novo, `GET /api/v1/message/{ID}/headers`; com `X-Cloudesk-Message-Id`, grava a resposta em `received.jsonl`; sem o header, o ID é marcado como visto e não gera registro;
- a API devolve o valor bruto dos headers; To, From e Subject passam por `email.header.decode_header`, que decodifica as palavras codificadas da RFC 2047 (`=?UTF-8?Q?Re:_Repasse_n=C3=A3o_recebido?=` vira `Re: Repasse não recebido`);
- os IDs vistos ficam em memória e em `data/mailpit_seen.jsonl`, relidos na partida;
- com o Mailpit fora do ar, o ciclo registra o erro em log e tenta de novo no ciclo seguinte.

O simulador não grava tags no Mailpit: o `PUT /api/v1/tags` substitui todas as tags das mensagens informadas, e não existe rota para acrescentar uma tag sozinha. A resposta do Core recebe `cloudesk-ignored` do `IngestJob` (F4).

## Registro

Cada linha é um objeto JSON, gravado com append e `flush`.

| Arquivo | Campos |
| - | - |
| `data/runs/<run_id>/sent.jsonl` | `run_id`, `channel`, `brand`, `contacts` (`seed` ou `new`), `identity`, `external_id`, `intent`, `attachment`, `sent_at`, `status`, `duration_ms`; no chat, `conversation_id`, `sequence` e `stream_status`; `error` quando a montagem ou o envio falha |
| `data/received.jsonl` | `channel`, `core_message_id`, `recipient`, `sender` (`phone_number_id` ou e-mail de suporte; nulo no chat), `received_at`; WhatsApp: `text` e `traceparent`; chat: `stream`, `author`, `text` e `sequence`; e-mail: `subject` e `mailpit_id` |
| `data/streams.jsonl` | `stream`, `app_user_id`, `registered_at` |
| `data/mailpit_seen.jsonl` | `mailpit_id` |

- `run_id`: horário UTC da execução (`20261119T171041Z`) e quatro caracteres aleatórios.
- `status`: status HTTP no WhatsApp e no chat; 250 no e-mail. Uma falha de montagem ou de envio vira registro com `status` igual ao nome da exceção (ou ao código SMTP) e `error`, e o comando segue com as demais mensagens.
- `recipient`: `to` do envio no WhatsApp (telefone sem `+`), `app_user_id` do stream no chat, To no e-mail.
- **Reconciliação (F17):** `core_message_id` repetido em `received.jsonl` é resposta duplicada. A mensagem perdida é medida contra `audit_events` (mensagem do lojista sem ação aceita que a cubra); `sent.jsonl` traz o `external_id` de cada envio, que o Core grava em `messages.external_id`.

## Comandos

Rodados no contêiner com `docker compose exec channel-simulator channel-simulator <comando>`. Os parâmetros são opções longas; aqui aparecem só pelo nome.

| Comando | Parâmetros | Efeito |
| - | - | - |
| `serve` | nenhum | Sobe os receptores (comando padrão da imagem) |
| `send` | `channel` (`whatsapp`, `chat`, `email` ou `all`), `brand` (`infinitepay`, `jim` ou `all`), `count`, `rate` (msg/s), `contacts` (`seed` ou `new`), `attachments` (fração de 0 a 1), `seed` | Envia `count` mensagens na taxa pedida, sorteando marca, canal, lojista e intenção com a semente; grava `data/runs/<run_id>/sent.jsonl` e imprime o resumo (enviadas e contagem por canal e status) |
| `scenario cross-channel` | `brand`, `seed` | Um lojista das seeds escreve por WhatsApp, chat e e-mail, nessa ordem; grava `sent.jsonl` e imprime o `conversation_id` devolvido pelo chat |
| `verify-whatsapp` | nenhum | Handshake `GET` do webhook |

O `send` agenda cada mensagem em `início + i / rate` e envia de forma concorrente: uma resposta lenta do Core não atrasa as seguintes. Os comandos registram os streams no `serve` em `http://localhost:<SIMULATOR_PORT>`, porque rodam no mesmo contêiner.

## Configuração

Serviço `channel-simulator` no `compose.yaml`, imagem `cloudesk-channel-simulator:dev`, porta 8080, dependente de `web` e `mailpit`. Volumes: `./channel_simulator` em `/app`, `./contracts` em `/contracts` (só leitura) e `./core/tmp/simulator` em `/personas` (só leitura).

| Variável | Uso |
| - | - |
| `CORE_URL` | Base das entradas do Core (`http://web:3000`) |
| `CORE_CABLE_URL`, `CORE_ORIGIN` | WebSocket do Action Cable e header `Origin` |
| `MAILPIT_API_URL` | API do Mailpit, para o poller |
| `SMTP_HOST`, `SMTP_PORT` | SMTP do Mailpit, para o envio |
| `WHATSAPP_APP_SECRET` | Assinatura `X-Hub-Signature-256` da entrada |
| `WHATSAPP_VERIFY_TOKEN` | Handshake `GET` |
| `WHATSAPP_ACCESS_TOKEN` | Bearer conferido no receptor |
| `CHAT_SIGNING_SECRET` | Assinatura da entrada do chat |
| `CONTRACTS_PATH` | Vetores de assinatura nos testes |
| `PERSONAS_PATH` | Arquivo exportado pela task |
| `SIMULATOR_DATA_DIR` | Pasta dos registros |
| `SIMULATOR_PORT` | Porta do `serve` |
| `MAILPIT_POLL_SECONDS` | Intervalo do poller |

No Core, `WHATSAPP_API_URL` é `http://channel-simulator:8080/v1`.

**Ordem de uso:** seeds; `docker compose exec web bin/rails simulator:personas`; `docker compose up -d channel-simulator`. Os comandos leem as personas a cada execução.

## Testes

| Arquivo | Cobertura |
| - | - |
| `tests/test_signature.py` | Vetores de assinatura do contrato |
| `tests/test_personas.py` | Leitura do arquivo; lojistas novos determinísticos com o código do país da marca |
| `tests/test_records.py` | JSONL com append e `flush` |
| `tests/test_templates.py` | Determinismo, locale, modelos por intenção, anexos |
| `tests/test_whatsapp.py` | Payload de texto, imagem e documento; assinatura; verificação com resposta certa e errada; receptor com Bearer certo, errado e ausente, corpo inválido e registro |
| `tests/test_chat.py` | Envio assinado; registro de streams (200, 400, 409, persistido e relido); parser do partial; cliente Action Cable (welcome, assinatura, mensagem, reconexão, assinatura recusada, welcome ausente, conexão parada) |
| `tests/test_email.py` | Montagem com e sem anexo; envio SMTP com 250, destinatário recusado e servidor fora do ar; poller (paginação, header ausente, ID já visto, IDs relidos, headers RFC 2047, Mailpit fora do ar) |
| `tests/test_sender.py` | Sorteio determinístico; `send` nos três canais; cenário entre canais; erro de montagem registrado; Core fora do ar |
| `tests/test_server.py` | Rotas, `GET /health` e streams relidos na partida |
| `core/spec/tasks/simulator_personas_spec.rb` | Marcas e canais, lojistas da própria marca com as três identidades, lojista incompleto fora, mesma saída em duas execuções |
| `core/spec/seeds_spec.rb` | E-mails dos lojistas em ASCII |

- Os testes do simulador rodam no contêiner: `docker compose exec channel-simulator pytest`.
- Os servidores falsos (Core, Action Cable, Mailpit) são apps `aiohttp` de teste; o SMTP falso é um `socketserver` em thread.

**Checagem ponta a ponta no Compose**, com `web`, `jobs-default`, `mailpit` e `channel-simulator`:

1. `verify-whatsapp`: 200 com o `challenge`.
2. `scenario cross-channel` na InfinitePay: três mensagens do mesmo `Contact` na mesma conversa, cada uma com `message.created`; o job de webhook existe quando o roteamento atribui a conversa à IA (`with_ai`), conforme `documents/fases/07-triagem-roteamento-e-distribuicao.md`.
3. `send` com `channel` e `brand` iguais a `all`, `count` 30, `rate` 5 e `attachments` 0,3: 30 linhas em `sent.jsonl` (10 por canal), status 200 ou 250, 30 mensagens no banco com `message.created`, e job de webhook para as mensagens das conversas em `with_ai`.
4. Respostas por `Conversations::Outbound.append!` a uma mensagem de cada canal da conversa do passo 2: três linhas em `received.jsonl`, uma por canal, com o id da `Message` do Core.
5. `Channels::DeliveryJob.perform_now` repetido para a resposta do WhatsApp: o mesmo `core_message_id` duas vezes em `received.jsonl`.
6. Reinício do `channel-simulator`: o Core confirma a assinatura de todos os streams, os e-mails já vistos não são registrados de novo, e uma resposta de chat posterior chega.

## Pronto quando

O critério é o de `contexto/ordem-de-implementacao.md`:

- o simulador alimenta os três canais do Core: passos 2 e 3 da checagem;
- o simulador registra todas as respostas recebidas, o que permite reconciliar o que foi enviado com o que voltou: passos 4 a 6.

## Pontos de atenção

- **Respostas de chat durante a queda do WebSocket.** O Turbo Stream não reenvia o que foi transmitido enquanto o simulador estava desconectado. Na F17, o simulador fica de pé durante a carga, e as falhas da H3 atingem Broker e worker, não o simulador.
- **Conexão do Action Cable sem assinaturas.** Caso observado uma vez na checagem ponta a ponta, sem causa determinada: o WebSocket aberto, nenhuma assinatura enviada e as respostas de chat sem registro; o processo reiniciado assina normalmente. O monitor de conexão parada e o fechamento na falha de assinatura cobrem `welcome` perdido, conexão sem ping e erro de envio; os logs de conexão e de assinatura identificam o caso. Antes da carga da F17, conferir no log do `web` a confirmação de cada stream (`Turbo::StreamsChannel is transmitting the subscription confirmation`).
- **E-mail fora da carga.** O poller do Mailpit atende o teste funcional, não 250 msg/s, conforme a arquitetura.
- **Personas desatualizadas.** Se as seeds mudarem, a task precisa ser rodada de novo antes dos comandos.
- **Lojistas já gravados.** As seeds buscam o lojista pelo telefone e não alteram um lojista existente: um e-mail gravado com acento no banco continua assim até que a identidade seja atualizada.
- **Sem Python na máquina.** Os testes do simulador rodam no contêiner.

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F3 | O simulador usa do contrato só a assinatura, no chat | `signature.py` é cópia do agente mock e roda os mesmos vetores |
| F8 | A resposta do agente sai por `Conversations::Outbound.append!` e chega ao simulador pelo canal de origem | O `received.jsonl` registra as respostas da ação `reply` sem mudança no simulador |
| F11 | A resposta do analista sai pelo mesmo serviço | O registro guarda o autor no chat (`author`) |
| F17 | O k6 chama direto as entradas de WhatsApp e chat | O k6 registra cada stream do chat em `POST /chat/streams`, com o `app_user_id`; a reconciliação lê `sent.jsonl`, `received.jsonl` e `audit_events` |

## Fontes

- Código da gem `actioncable` 8.1.4.1 na imagem `cloudesk-core:dev` (`server/connections.rb`: `BEAT_INTERVAL = 3`; `connection/base.rb`; `app/assets/javascripts/actioncable.js`: `ConnectionMonitor.staleThreshold = 6`)
- Código do `smtplib` na imagem `python:3.13-slim` (`sendmail`: `SMTPDataError` para resposta diferente de 250 ao `DATA`)
- [Mailpit · API v1](https://mailpit.axllent.org/docs/api-v1/)
- [Mailpit · Swagger da API](https://raw.githubusercontent.com/axllent/mailpit/master/server/ui/api/v1/swagger.json)
- [Mailpit · Search filters](https://mailpit.axllent.org/docs/usage/search-filters/)
- [Meta · WhatsApp Cloud API, exemplos de payload de webhook](https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples/)
- [Meta · WhatsApp Cloud API, referência de envio de mensagens](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages/)
