# Cloudesk · F4 · Canais de entrada e identidade

## Objetivo

A F4 recebe as mensagens dos três canais (WhatsApp, chat in-app e e-mail), reconhece o lojista, abre ou reabre a conversa e grava a mensagem pelo serviço de comando da F2. Ela também entrega as respostas de volta a cada canal.

Este documento detalha cada decisão e a fonte que a sustenta. O resumo está em `documents/arquitetura.md`, que prevalece; a lista de entregas e o critério de pronto estão em `contexto/ordem-de-implementacao.md`.

## Resumo das decisões

| Tema | Decisão |
| - | - |
| Caminho de entrada | Cada canal só traduz para `Channels::InboundMessage`; o caminho único é `Conversations::Intake` |
| Marca da mensagem | Tabela `brand_channels`, fora do RLS, com os números de WhatsApp e os e-mails de suporte de cada marca; o chat leva a marca na URL |
| Normalização | Telefone em E.164 com `+`; e-mail em minúsculas e sem espaços; id do app como chega |
| Remetente desconhecido | Novo `Contact` com uma identidade; sem união automática entre contatos |
| Conversa | Uma conversa não `closed` por lojista, em qualquer canal |
| Prazo de reabertura | `brands.reopen_window_minutes`, padrão 1440 (24 h); conferido na entrada e por job recorrente |
| Mensagem repetida | `messages.external_id` com índice único por marca e canal; o reenvio recebe 200 e não produz efeito |
| WhatsApp | Formato da Cloud API; verificação por `GET`; assinatura `X-Hub-Signature-256`; payload inteiro em uma transação por marca |
| Chat | Entrada JSON assinada (simulador e k6) e widget Hotwire; saída por Turbo Stream, no stream do lojista |
| E-mail | Webhook do Mailpit e varredura recorrente; Action Mailbox com `SupportMailbox` |
| Anexos | Só metadados em `messages.attachments`; texto padrão no locale da marca quando não há texto |
| Saída | `Channels::DeliveryJob` na fila `channels`, enfileirado na transação da mensagem; `message.delivered` depois da entrega |
| Tabelas das gems | Active Storage e Action Mailbox sem `brand_id` e sem RLS, com a chave primária `bigint` das gems |
| Filas do Action Mailbox | `action_mailbox_routing` e `action_mailbox_incineration`, fixadas em `config/application.rb` |
| Processo | Serviço `jobs-default` no Compose, com `bin/jobs` |

## Premissas

O TAPI não define como cada canal identifica a marca. Os canais são simulados, e a F4 adota premissas que imitam o funcionamento real:

- cada marca tem números de WhatsApp próprios, e o payload da Cloud API traz o `phone_number_id` do número que recebeu a mensagem;
- cada marca tem e-mails de suporte próprios;
- cada marca tem o seu app, e o chat leva o slug da marca na URL;
- os valores são fictícios e vêm das seeds: dois números de WhatsApp e dois e-mails por marca, no domínio reservado `.test`;
- o cadastro de lojistas das seeds faz o papel do cadastro da CloudWalk: cada lojista tem telefone, e-mail e id do app já ligados.

| Marca | `phone_number_id` (número exibido) | E-mails de suporte |
| - | - | - |
| InfinitePay | `110000000000001` (`551140000001`), `110000000000002` (`551140000002`) | `suporte@infinitepay.test`, `financeiro@infinitepay.test` |
| JIM | `120000000000001` (`15555550101`), `120000000000002` (`15555550102`) | `support@jim.test`, `payouts@jim.test` |

## Arquivos

| Arquivo | Conteúdo |
| - | - |
| `core/db/migrate/20261119120000_create_active_storage_tables.active_storage.rb` | Tabelas do Active Storage, da gem |
| `core/db/migrate/20261119120100_create_action_mailbox_tables.action_mailbox.rb` | Tabela do Action Mailbox, da gem |
| `core/db/migrate/20261119120200_create_channel_tables.rb` | `brand_channels`, colunas novas, índices e permissões |
| `core/app/models/brand_channel.rb` | Número ou e-mail de uma marca |
| `core/app/modules/channels/identity.rb` | Normalização das identidades |
| `core/app/modules/channels/inbound_message.rb` | Envelope canônico de entrada |
| `core/app/modules/channels/attachment_text.rb` | Texto padrão de mensagem sem texto |
| `core/app/modules/channels/settings.rb` | Segredos e endereços dos canais, lidos do ambiente |
| `core/app/modules/conversations/intake.rb` | Caminho único de entrada |
| `core/app/modules/conversations/outbound.rb` | Gravação da resposta e enfileiramento da entrega |
| `core/app/modules/conversations/close_expired_job.rb` | Varredura do prazo de reabertura |
| `core/app/modules/channels/whatsapp/` | Assinatura, leitura do payload e envio do WhatsApp |
| `core/app/modules/channels/chat.rb` | Stream Turbo do lojista |
| `core/app/modules/channels/mailpit/client.rb` | Cliente da API do Mailpit |
| `core/app/modules/channels/email/` | `IngestJob` e `SweepJob` |
| `core/app/modules/channels/delivery_job.rb`, `delivery_error.rb` | Entrega das respostas |
| `core/app/controllers/channels/` | Webhook do WhatsApp, entrada JSON do chat, widget e webhook do Mailpit |
| `core/app/mailboxes/` | `ApplicationMailbox` e `SupportMailbox` |
| `core/app/mailers/channels/reply_mailer.rb` | Resposta por e-mail |
| `core/app/views/channels/` | Widget, partial da mensagem e corpo do e-mail |
| `core/app/javascript/controllers/chat_message_controller.js` | Gera o `client_message_id` no navegador |
| `core/config/locales/pt-BR.yml`, `en-US.yml` | Textos padrão de anexo |
| `core/spec/` | Testes |

## Banco

Migração `CreateChannelTables`, executada com o papel dono depois das migrações das gems.

**`brand_channels`** (fora do RLS):

| Coluna | Tipo |
| - | - |
| `id` | uuid, default `uuidv7()` |
| `brand_id` | uuid, `NOT NULL`, chave estrangeira para `brands` |
| `channel` | string, `NOT NULL`, check `channel IN ('whatsapp', 'email')` |
| `value` | string, `NOT NULL`: `phone_number_id` ou e-mail normalizado |
| `display_value` | string: número exibido no WhatsApp; no e-mail, igual a `value` |
| `created_at`, `updated_at` | datetime |

- Índice único em `(channel, value)`: o par define a marca.
- Índice único em `(brand_id, id)`: alvo da chave estrangeira composta de `messages`.
- O papel da aplicação só tem `SELECT`; os registros vêm das seeds.

**`brands`:** `reopen_window_minutes` integer `NOT NULL DEFAULT 1440`, com check `> 0`.

**`messages`:**

- `external_id` string, aceita nulo; índice único parcial em `(brand_id, channel, external_id) WHERE external_id IS NOT NULL`.
- `attachments` jsonb `NOT NULL DEFAULT '[]'`.
- `brand_channel_id` uuid, aceita nulo (chat); chave estrangeira composta `(brand_id, brand_channel_id)` para `brand_channels (brand_id, id)`, sem ação `ON DELETE`; índice em `(brand_id, brand_channel_id)`.

**`conversations`:**

- Índice único parcial em `(brand_id, contact_id) WHERE state <> 'closed'`: uma conversa não `closed` por lojista.
- Índice parcial em `(brand_id, resolved_at) WHERE state = 'resolved'`, para a varredura do prazo.

**Active Storage e Action Mailbox:** `active_storage_blobs`, `active_storage_attachments`, `active_storage_variant_records` e `action_mailbox_inbound_emails`, com o conteúdo das migrações das gems, chave primária `bigint`, sem `brand_id` e sem RLS. O papel da aplicação recebe `SELECT`, `INSERT`, `UPDATE`, `DELETE` e o uso das sequences. As tabelas do Action Text não existem.

**Embasamento.**

- Toda escrita de domínio exige a marca definida na transação, e a mesma identidade pode existir nas duas marcas. A marca é descoberta pelo número ou pelo e-mail que recebeu a mensagem, antes de `Tenancy.with_brand`; por isso `brand_channels` fica fora do RLS, como `brands`.
- O e-mail chega ao Action Mailbox antes de a marca ser conhecida, e a incineração apaga linhas de `action_mailbox_inbound_emails`. Nenhuma tabela de domínio aponta para as tabelas das gems.
- As migrações das gems usam o tipo de chave primária do gerador do app, que não define `primary_key_type`; o resultado é `bigint`.
- A chave estrangeira composta de `brand_channel_id` segue a regra da F1: a checagem de chave estrangeira ignora o RLS, e a chave composta impede apontar para o canal de outra marca.

## Entrada

```text
WhatsApp (simulador no papel da Meta) ── POST assinado ──┐
Chat (widget ou simulador)            ── POST ───────────┼─→ adaptador do canal ─→ Channels::InboundMessage
E-mail: lojista → SMTP → Mailpit ── webhook ─→ IngestJob ─→ InboundEmail ─→ SupportMailbox ┘
                                                                                          ↓
                                                              Conversations::Intake (1 transação)
                                             marca → lojista → conversa → mensagem → audit_events → job de webhook
```

### Camadas

1. **Autenticidade.** WhatsApp: `X-Hub-Signature-256`. Chat: `Contract::Signature`, com o segredo `CHAT_SIGNING_SECRET`. E-mail: basic auth do webhook do Mailpit.
2. **Marca.** `brand_channels` diz de qual marca é o número ou o e-mail que recebeu a mensagem; o chat traz a marca na URL ou no corpo.
3. **Intake**, em uma transação.

### Envelope de entrada

`Channels::InboundMessage` (`Data`): `brand`, `brand_channel` (nulo no chat), `channel`, `identity` (normalizada), `contact_name`, `external_id`, `text`, `attachments`, `received_at` e `subject` (só no e-mail).

Normalização (`Channels::Identity.normalize`):

| Canal | Regra | Exemplo |
| - | - | - |
| `whatsapp` | Só dígitos, com `+` na frente | `16505551234` → `+16505551234` |
| `email` | `strip.downcase` | ` Lojista@Example.COM ` → `lojista@example.com` |
| `chat` | `strip` | ` app-AbC ` → `app-AbC` |

As seeds gravam o telefone com `+`, e o `wa_id` da Cloud API vem sem `+`; um único formato faz a busca casar.

### Intake

`Conversations::Intake.call(inbound_messages)` recebe uma ou mais mensagens da mesma marca e grava todas em um `Tenancy.with_brand`, com os `Audit::Command` aninhados. Para cada mensagem:

1. `external_id` já gravado na marca e no canal: é reenvio; devolve a mensagem existente, sem novo efeito.
2. Busca a identidade. Sem identidade, cria `Contact` (nome do canal, ou a própria identidade; locale da marca) e `ContactIdentity` (`contact.created`).
3. Busca a conversa não `closed` do lojista com `FOR UPDATE`:
   - nenhuma: abre, no canal da mensagem (`conversation.opened`);
   - `resolved` com `resolved_at` dentro do prazo: `resolved → triage` (`conversation.reopened`);
   - `resolved` com `resolved_at` anterior a `received_at` menos o prazo: `resolved → closed` (`conversation.closed`) e abre outra;
   - qualquer outro estado: usa a conversa.
4. Com a conversa em `triage`, classifica e roteia por `Routing::Route` (`documents/fases/07-triagem-roteamento-e-distribuicao.md`).
5. Grava a mensagem com a próxima sequência (`message.created`, com webhook ao Broker só com a conversa em `with_ai`).

| Evento | Ator | Webhook ao Broker |
| - | - | - |
| `contact.created` | `system` | não |
| `conversation.opened` | `system` | não |
| `conversation.reopened` | `system`, com motivo | não |
| `conversation.closed` | `system`, com motivo | não |
| `message.created` do lojista | `customer`, com `actor_id` do `Contact` | sim, com a conversa em `with_ai` |

O payload do `message.created` mantém `payload.message` no formato do contrato (`author`, `channel`, `text`), que `Contract::MessageCreated.build` lê. Os demais campos ficam no `audit_event`, fora do webhook:

| Campo | Uso |
| - | - |
| `external_id` | Id do canal; no e-mail, o `Message-ID`, usado no `In-Reply-To` da resposta |
| `attachments` | Metadados dos anexos |
| `identity` | Identidade que escreveu; é o destinatário da resposta |
| `subject` | Assunto do e-mail; é o assunto da resposta |

Todos os eventos de uma chamada compartilham o `traceparent` corrente e usam o `received_at` da mensagem.

**Corrida.** Duas primeiras mensagens simultâneas do mesmo lojista batem nos índices únicos (identidade, conversa aberta por lojista, `external_id`). A transação que perde é desfeita inteira e tentada de novo, até 3 vezes, e na nova tentativa encontra o que a outra criou. A nova tentativa fica fora do `Tenancy.with_brand`, porque no PostgreSQL a transação com erro fica abortada.

**Mensagem sem texto.** O texto da mensagem é o texto padrão do primeiro anexo, no locale da marca: `[imagem enviada]`, `[documento enviado]`, `[áudio enviado]`, `[vídeo enviado]` ou `[conteúdo enviado]` em `pt-BR`; `[image sent]`, `[document sent]`, `[audio sent]`, `[video sent]` ou `[content sent]` em `en-US`. Sem anexo, o texto é o de "outro conteúdo".

**Embasamento.**

- Unir contatos por nome ou texto livre pode juntar dois lojistas e expor dados financeiros de um ao outro; por isso o remetente desconhecido vira um `Contact` novo.
- O histórico entre canais fica numa só conversa. O tamanho dela é limitado pelo ciclo de vida: depois do prazo de reabertura, nova mensagem abre outra conversa. Assunto novo é tratado pela ação `categorize` (F8).
- O id externo é gerado por quem envia (`wamid`, `Message-ID`, id do cliente no chat). O mesmo id é reenvio técnico; texto igual com id diferente é mensagem nova.
- O prazo é conferido na entrada, além da varredura: a regra fica correta mesmo com atraso do job recorrente.

### `Tenancy` e o query cache

O Rails liga o query cache em requisições e jobs. `Tenancy` lê e grava `app.brand_id` com `SELECT current_setting(...)` e `SELECT set_config(...)`, e as duas consultas rodam com `connection.uncached`. Com o cache, um `current_setting` devolveria um valor antigo e um `set_config` repetido deixaria de ser executado, e o bloco externo ficaria sem marca depois de um bloco aninhado. O teste "mantém a marca do bloco externo depois de blocos aninhados com o query cache ligado", em `core/spec/tenancy/brand_isolation_spec.rb`, cobre o caso.

## WhatsApp

- `GET /channels/whatsapp/webhook`: com `hub.mode == "subscribe"` e `hub.verify_token` igual a `WHATSAPP_VERIFY_TOKEN` (comparação em tempo constante), responde 200 com o `hub.challenge` em `text/plain`; senão, 403.
- `POST /channels/whatsapp/webhook`: confere `X-Hub-Signature-256` (`sha256=` seguido do HMAC-SHA256 hexadecimal do corpo bruto, com `WHATSAPP_APP_SECRET`). Assinatura ausente ou inválida: 401.
- `Channels::Whatsapp::Payload` percorre `entry[].changes[]` com `field == "messages"`:
  - marca e `BrandChannel` por `value.metadata.phone_number_id`; número desconhecido é ignorado com log e recebe 200, porque a Meta reenviaria uma resposta de erro sem fim;
  - nome do lojista em `value.contacts[]`, casando `wa_id` com `messages[].from`;
  - `text`: texto de `text.body`;
  - `image`, `document`, `audio` e `video`: anexo com `kind`, `content_type` (o `mime_type` da Meta) e `filename` quando existe; texto da `caption`, ou o texto padrão;
  - outros tipos: anexo `other` e o texto padrão;
  - `external_id` é o `wamid`; a identidade é `messages[].from` normalizado; mensagem sem `from` é ignorada com log;
  - `value.statuses` é ignorado.
- As mensagens do payload vão ao Intake em uma transação por marca, e o 200 sai depois do commit.

## Chat

**Entrada JSON**, para o simulador e o k6: `POST /channels/chat/messages`.

```json
{ "brand": "infinitepay", "app_user_id": "app-…", "client_message_id": "…", "text": "…",
  "attachments": [ { "kind": "image", "filename": "…", "content_type": "…", "size": 123 } ] }
```

- Assinatura `Contract::Signature` com `CHAT_SIGNING_SECRET`, sobre método, caminho e corpo bruto. Inválida, vencida ou ausente: 401.
- Marca desconhecida, `app_user_id` ou `client_message_id` vazios, anexo sem `kind` válido, ou mensagem sem texto e sem anexo: 422.
- Resposta 200: `{ "conversation_id", "sequence", "stream" }`, em que `stream` é o nome assinado do stream Turbo do lojista (`Turbo::StreamsChannel.signed_stream_name`). O reenvio do mesmo `client_message_id` devolve a mesma resposta.

**Widget** (Hotwire), com login simulado e o `app_user_id` na sessão, por marca:

| Rota | Função |
| - | - |
| `GET /chat/:brand` | Lojistas da marca com identidade de chat |
| `POST /chat/:brand/session` | Grava o lojista escolhido na sessão |
| `GET /chat/:brand/conversation` | Histórico da conversa aberta, com o canal de cada mensagem, e `turbo_stream_from` do lojista |
| `POST /chat/:brand/messages` | Envio pelo formulário, com CSRF; `client_message_id` gerado no navegador (`crypto.randomUUID()`) |

- O stream é por lojista (`[contact, :chat]`), não por conversa: o widget continua inscrito quando uma conversa nova é aberta.
- O envio redireciona para a conversa (303), que mostra a mensagem gravada.
- Sem upload de arquivos.
- O Action Cable atende em `/cable`, a rota padrão do Rails, e o Solid Cable é o adaptador em desenvolvimento.

## E-mail

1. **Chegada.** O e-mail chega por SMTP ao Mailpit, que guarda tudo o que recebe.
2. **Webhook.** O Mailpit faz `POST` do resumo da mensagem para `/channels/email/mailpit`, com basic auth na URL (`MP_WEBHOOK_URL`) e `MP_WEBHOOK_LIMIT=0`. O endpoint lê só o `ID`, enfileira `Channels::Email::IngestJob` e responde 200. Sem basic auth válido: 401.
3. **`IngestJob`** (fila `default`). Baixa o original (`GET /api/v1/message/{ID}/raw`) e confere To e Cc e o remetente contra `brand_channels`:
   - algum destinatário é e-mail de suporte e o remetente não é: cria o `InboundEmail` (`ActionMailbox::InboundEmail.create_and_extract_message_id!`) e marca a tag `cloudesk-ingested`;
   - caso contrário, inclusive a resposta do próprio Core ao lojista: marca a tag `cloudesk-ignored` e não cria nada.

   Com o Mailpit fora do ar, o job tenta de novo com backoff exponencial e jitter.
4. **Roteamento.** Depois do commit do `InboundEmail`, o Action Mailbox enfileira o `ActionMailbox::RoutingJob` na fila `action_mailbox_routing`. O `ApplicationMailbox` manda todo e-mail ao `SupportMailbox`.
5. **`SupportMailbox`:**
   - `BrandChannel` pelo primeiro destinatário (To, depois Cc) presente em `brand_channels`; sem nenhum, ou sem remetente, o e-mail é marcado `bounced`, sem envio de e-mail;
   - `received_at` é a criação do `InboundEmail`, e o trace começa aqui;
   - identidade: endereço do From normalizado; nome: nome de exibição do From, ou a parte local do endereço;
   - `external_id`: `Message-ID`; `subject`: assunto;
   - texto: parte `text/plain`; sem ela, o HTML sem tags (`Rails::HTML5::FullSanitizer`). Saem as linhas que começam com `>` e tudo a partir de uma linha "On … wrote:" ou "Em … escreveu:";
   - anexos: `kind` (`image`, `audio`, `video` pelo tipo MIME; os demais, `document`), `filename`, `content_type` e `size`.
6. **Varredura.** `Channels::Email::SweepJob`, a cada minuto, busca as mensagens sem tag (`GET /api/v1/search?query=!is:tagged`), página a página, e enfileira um `IngestJob` por mensagem. Toda mensagem tratada recebe tag, e a busca devolve só o que o webhook perdeu.

**Unicidade.** O índice único de `action_mailbox_inbound_emails` em (`message_id`, `message_checksum`) impede o mesmo e-mail duas vezes: o método da gem trata a colisão e devolve `nil`. O método grava o e-mail original no Active Storage antes do `InboundEmail`; na colisão, esse blob fica sem anexo.

**Filas.** O engine do Action Mailbox define as filas `action_mailbox_routing` e `action_mailbox_incineration`, e o `config.load_defaults` do app as deixa vazias, o que mandaria os jobs para a fila `default`. O `config/application.rb` fixa as duas filas.

**Embasamento.**

- O Mailpit faz `POST` do resumo de cada mensagem recebida para `MP_WEBHOOK_URL`, com basic auth na URL. Chamadas com falha não são reenviadas, e o limite padrão de 1 chamada por segundo ignora o excedente; `MP_WEBHOOK_LIMIT=0` desliga o limite.
- O filtro `to:` do Mailpit é por trecho do campo, não por endereço exato; o filtro por destinatário fica no Core, sobre o e-mail original.
- O filtro por destinatário impede que as respostas do Core voltem como entrada.
- No código da gem `actionmailbox` 8.1.4.1, `create_and_extract_message_id!` trata `ActiveRecord::RecordNotUnique` e devolve `nil`, e `after_create_commit :route_later` enfileira o roteamento. O `railties` 8.1.4.1, nos defaults da versão 6.1, define `action_mailbox.queues.routing` e `incineration` como `nil`.
- O ingress `relay` do Action Mailbox não é usado.
- O Action Mailbox incinera o `InboundEmail` processado depois de 30 dias. A resposta lê assunto e `Message-ID` do `audit_event`, e não do `InboundEmail`.

## Saída

```text
mensagem do atendente → Conversations::Outbound.append! → Channels::DeliveryJob → WhatsApp (POST ao simulador)
                                                                               → E-mail (SMTP ao Mailpit)
                                                                               → Chat (Turbo Stream por Solid Cable)
```

`Conversations::Outbound.append!(conversation:, author:, text:, in_reply_to_sequence:, attendant:)`:

- aceita os autores `ai`, `analyst` e `system`;
- acha a mensagem respondida pela sequência; o canal e a `BrandChannel` vêm dela, e a resposta sai do mesmo número ou do mesmo e-mail;
- grava a mensagem por `Audit::Command` (`message.created`, `actor_type` igual ao autor, payload com `in_reply_to_sequence`, sem webhook ao Broker);
- enfileira `Channels::DeliveryJob` com `brand_id`, `message_id` e `traceparent` dentro do bloco do comando, na mesma transação (outbox).

A F8 (agente) e a F11 (analista) chamam esse serviço; na F8, `in_reply_to_sequence` é a última mensagem do lojista com sequência menor ou igual ao `based_on_sequence` da ação. A entrega lê o destinatário (`identity`) do `message.created` da mensagem respondida, campo que só a mensagem do lojista tem.

`Channels::DeliveryJob` (fila `channels`, `enqueue_after_transaction_commit = false`) lê a mensagem e os payloads dos `message.created` em `audit_events`:

| Canal | Entrega |
| - | - |
| WhatsApp | `POST {WHATSAPP_API_URL}/{phone_number_id}/messages`, com `Authorization: Bearer {WHATSAPP_ACCESS_TOKEN}`, `X-Cloudesk-Message-Id` e `traceparent`. Corpo `{ "messaging_product": "whatsapp", "recipient_type": "individual", "to": "<telefone sem +>", "type": "text", "text": { "body": "…" } }`. O destinatário é a identidade que escreveu a mensagem respondida |
| E-mail | `Channels::ReplyMailer#reply` com `deliver_now!`. From: e-mail da `BrandChannel`; To: a identidade que escreveu a mensagem respondida; Subject: `Re: ` mais o assunto do último e-mail do lojista na conversa, sem repetir o prefixo; `In-Reply-To` e `References`: `Message-ID` desse e-mail; header `X-Cloudesk-Message-Id` |
| Chat | `Turbo::StreamsChannel.broadcast_append_to` no stream do lojista, alvo `messages`, com o partial da mensagem e o id dela |

- Resposta 2xx do WhatsApp é sucesso. 5xx e erro de rede lançam `Channels::DeliveryError::Transient`, e o job tenta de novo com backoff exponencial e jitter (2^n segundos mais até 15%), até 10 execuções. 4xx lança `Channels::DeliveryError::Permanent`: o job falha sem nova tentativa e fica na fila de falhas do Solid Queue.
- No e-mail, `deliver_now!` lança o erro de entrega qualquer que seja `raise_delivery_errors`; os erros transitórios de SMTP geram nova tentativa.
- Depois da entrega, o job grava `message.delivered` (`actor_type: "system"`, alvo a mensagem, payload com canal e `delivered_at`). O horário da entrega é o fim da medida da H4.
- A entrega é at-least-once: uma queda entre o envio e a gravação de `message.delivered` repete o envio. O id da mensagem do Core segue em cada entrega, e a reconciliação da F17 detecta a repetição.

## Prazo de reabertura

`Conversations::CloseExpiredJob` (fila `default`), a cada minuto: para cada `Brand`, em `Tenancy.with_brand`, lê em lotes de 100, com `FOR UPDATE SKIP LOCKED`, as conversas `resolved` com `resolved_at` anterior a agora menos `reopen_window_minutes`. Cada uma vai a `closed` por `Audit::Command` (`conversation.closed`, `actor_type: "system"`, motivo "prazo de reabertura vencido").

## Configuração e processos

| Arquivo | Conteúdo |
| - | - |
| `config/queue.yml` | Worker com as filas `default`, `channels`, `action_mailbox_routing` e `action_mailbox_incineration`, em todos os ambientes. A fila `webhooks` fica para o `jobs-webhooks` da F7 |
| `config/recurring.yml` | `close_expired_conversations` e `sweep_mailpit`, a cada minuto, em `development` e `production` |
| `config/application.rb` | Filas do Action Mailbox |
| `config/environments/development.rb` | `action_mailer.delivery_method = :smtp` com `SMTP_HOST` e `SMTP_PORT`; `config.hosts << "web"`, porque o webhook do Mailpit chama o Core pelo nome do serviço |
| `config/environments/test.rb` | `action_mailer.delivery_method = :test` |
| `compose.yaml` | Variáveis dos canais em `x-rails`; serviço `jobs-default` com `bin/jobs`; `MP_WEBHOOK_URL` e `MP_WEBHOOK_LIMIT=0` no `mailpit` |
| `.env.example` | Variáveis dos canais, com a orientação de gerar cada segredo como texto aleatório (`openssl rand -hex 32`) |
| `Gemfile` | `webmock` no grupo `test` |

| Variável | Uso |
| - | - |
| `WHATSAPP_APP_SECRET` | Assinatura `X-Hub-Signature-256` |
| `WHATSAPP_VERIFY_TOKEN` | Verificação `GET` do webhook |
| `WHATSAPP_ACCESS_TOKEN` | Bearer token do envio |
| `WHATSAPP_API_URL` | Base do envio, com o segmento de versão; o valor é o endereço do simulador (F5) |
| `CHAT_SIGNING_SECRET` | Assinatura da entrada JSON do chat |
| `MAILPIT_WEBHOOK_USER`, `MAILPIT_WEBHOOK_PASSWORD` | Basic auth do webhook do Mailpit |
| `MAILPIT_API_URL` | API do Mailpit (`http://mailpit:8025`) |
| `SMTP_HOST`, `SMTP_PORT` | SMTP do Mailpit (`mailpit`, `1025`) |

Os segredos são textos aleatórios gerados para o projeto; não existe conta na Meta nem custo.

## Seeds

Por marca, `BrandChannel.find_or_create_by!(channel:, value:)` cria os dois números de WhatsApp e os dois e-mails da tabela de premissas. `reopen_window_minutes` fica no padrão da coluna. Rodar as seeds de novo continua sem duplicar registros.

## Testes

| Arquivo | Cobertura |
| - | - |
| `spec/models/channel_schema_spec.rb` | `brand_channels` visível sem marca e só leitura para a aplicação; uma conversa aberta por lojista; `external_id` único por marca e canal; chave estrangeira de `brand_channel_id`; formato dos anexos; permissões nas tabelas das gems; normalização |
| `spec/modules/conversations/intake_spec.rb` | Abertura, reabertura dentro do prazo, fechamento e nova conversa depois do prazo; reenvio sem efeito; lojista desconhecido; o mesmo lojista em WhatsApp e e-mail como um `Contact` e uma conversa; payload e job de webhook; texto padrão; corrida entre duas primeiras mensagens |
| `spec/requests/channels/whatsapp_webhooks_spec.rb` | Verificação `GET`; assinatura válida, inválida e ausente; texto, imagem com e sem legenda, documento, tipo sem suporte, statuses, número desconhecido, várias mensagens, reenvio |
| `spec/requests/channels/chat_messages_spec.rb` | Assinatura válida, inválida, vencida e ausente; resposta com `stream`; reenvio; anexos; 422 |
| `spec/requests/channels/chat_widget_spec.rb` | Lista de lojistas, sessão, envio pelo formulário e histórico com o canal de cada mensagem |
| `spec/requests/channels/mailpit_webhooks_spec.rb` | Webhook com e sem basic auth |
| `spec/modules/channels/email/ingest_job_spec.rb` | E-mail de suporte vira `InboundEmail` e tag; Cc; resposta do Core e e-mail sem suporte recebem `cloudesk-ignored`; nova tentativa; o mesmo e-mail duas vezes cria um `InboundEmail`; fila do roteamento |
| `spec/modules/channels/email/sweep_job_spec.rb` | Mensagens sem tag geram `IngestJob`, com paginação |
| `spec/mailboxes/support_mailbox_spec.rb` | Texto, trecho citado, HTML sem parte de texto, anexos, nome do lojista novo, destinatário sem marca |
| `spec/modules/channels/delivery_job_spec.rb` | `Outbound`; WhatsApp (corpo, headers, 5xx, erro de rede, 4xx); e-mail (From, To, assunto, `In-Reply-To`, `References`); broadcast do chat; `message.delivered`; resposta no canal da mensagem respondida |
| `spec/modules/conversations/close_expired_job_spec.rb` | Fecha só as vencidas, em cada marca, com o prazo de cada marca |
| `spec/tenancy/brand_isolation_spec.rb` | Marca do bloco externo com o query cache ligado |

- As chamadas HTTP de saída (Mailpit, WhatsApp) são simuladas pelo `webmock`, e os segredos dos canais têm valores fixos nos testes (`spec/support/channels.rb`).
- Dois exemplos rodam fora da transação do RSpec, com commit de verdade:
  - a corrida do Intake. `audit_events` não aceita `DELETE`; a limpeza roda com o papel dono, que desliga o trigger `audit_events_block_row_changes` só durante a limpeza, na mesma transação;
  - o mesmo e-mail duas vezes, porque a colisão no índice único abortaria a transação do RSpec. A limpeza apaga o `InboundEmail`, os blobs e os jobs gravados pelo exemplo.

## Pronto quando

O critério é o de `contexto/ordem-de-implementacao.md`:

- uma mensagem de cada canal vira `Message` com `audit_event` e job de webhook: `intake_spec.rb`, os testes de request do WhatsApp e do chat e `support_mailbox_spec.rb`;
- o mesmo lojista em WhatsApp e e-mail aparece como um único `Contact`: `intake_spec.rb`.

O caminho também roda no Compose, com `web`, `jobs-default` e `mailpit`: uma mensagem de WhatsApp assinada, uma do chat e um e-mail por SMTP ao Mailpit do mesmo lojista das seeds viram três mensagens na mesma conversa, com `message.created` e job de webhook; a resposta por e-mail volta ao Mailpit com a tag `cloudesk-ignored`.

## Pontos de atenção

- **Entrega at-least-once.** Uma queda entre o envio ao canal e a gravação de `message.delivered` repete o envio; o id da mensagem segue em cada entrega para a reconciliação.
- **Identificação no WhatsApp.** A Meta indica que `messages[].from` pode faltar quando o usuário usa nome de usuário, com `from_user_id` como identificador. O simulador sempre envia `from`; a falta de `from` gera log e a mensagem é ignorada.
- **Relógio.** O `received_at` do e-mail é a criação do `InboundEmail`, posterior à chegada no Mailpit. O e-mail fica fora do experimento de carga.
- **Tabelas sem RLS.** `brand_channels`, Active Storage e Action Mailbox não têm isolamento por marca no banco. `brand_channels` só tem leitura para a aplicação; o e-mail original fica acessível só pelo código do Core.
- **Itens da Cloud API não confirmados na documentação oficial lida:** campos de áudio e vídeo, `text.body` no envio, e o formato da assinatura e da verificação (fontes de terceiros consistentes). Eles afetam só a fidelidade ao formato real; o simulador (F5) produz e consome os mesmos formatos.

## Proposta à CloudWalk: verificação de identidade

Para unir com segurança dois contatos que o cadastro não liga, o sistema envia um código ao telefone ou ao e-mail cadastrado, e o lojista confirma. Fica fora do escopo do projeto.

## União manual de contatos

O analista une dois `Contact` do mesmo lojista, por exemplo um WhatsApp e um e-mail que o cadastro não liga, e a união gera `audit_event`. A ideia está registrada em `contexto/ideias.md` (ideia 8).

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F5 | O simulador faz o papel da Meta e do lojista | Envia nos formatos desta fase, assina o WhatsApp e o chat, assina o stream Turbo devolvido pelo chat e recebe o `POST` do envio do WhatsApp; define `WHATSAPP_API_URL` |
| F6 | A conversa em `triage` passa por `Routing::Route` na transação do Intake | O webhook do `message.created` sai só com a conversa em `with_ai` |
| F7 | A fila `webhooks` não está no worker do `jobs-default` | O `jobs-webhooks` processa a fila |
| F8 | A resposta sai por `Conversations::Outbound.append!` | A ação `reply` chama o serviço com `in_reply_to_sequence` igual à última mensagem do lojista até o `based_on_sequence` |
| F11 | O analista responde pelo mesmo serviço | Autor `analyst`, com o `Attendant` |
| F17 | `message.delivered` tem o horário da entrega | É o fim da medida da H4 e a base da reconciliação |

## Fontes

- [Mailpit · Webhook](https://mailpit.axllent.org/docs/integration/webhook/)
- [Mailpit · API v1](https://mailpit.axllent.org/docs/api-v1/)
- [Mailpit · Swagger da API](https://raw.githubusercontent.com/axllent/mailpit/master/server/ui/api/v1/swagger.json)
- [Mailpit · Search filters](https://mailpit.axllent.org/docs/usage/search-filters/)
- [Rails Guides · Action Mailbox Basics](https://guides.rubyonrails.org/action_mailbox_basics.html)
- Código das gems `actionmailbox` 8.1.4.1 e `railties` 8.1.4.1 na imagem `cloudesk-core:dev`
- [Meta · WhatsApp Cloud API, exemplos de payload de webhook](https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples/)
- [Meta · WhatsApp Cloud API, referência de envio de mensagens](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages/)
- [Meta · Webhook de mensagem de imagem](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/image)
- [Meta · Webhook de mensagem de documento](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/document/)
- [Meta · Webhook de mensagem de vídeo](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/video)
- [Hookdeck · Guia de webhooks do WhatsApp](https://hookdeck.com/webhooks/platforms/guide-to-whatsapp-webhooks-features-and-best-practices) (assinatura e verificação, fonte de terceiros)
- [Webhook Relay · Verificar a assinatura do webhook do WhatsApp](https://webhookrelay.com/verify-whatsapp-webhook-signature/) (assinatura, fonte de terceiros)
