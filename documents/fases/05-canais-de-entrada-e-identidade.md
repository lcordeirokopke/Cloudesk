# Cloudesk · Canais de entrada e identidade

## O que é

Os canais de entrada e identidade são a fronteira entre o Cloudesk e o lojista. Esta parte do sistema:

- **recebe** as mensagens dos três canais: WhatsApp, no formato da Cloud API da Meta; chat no app, por uma entrada JSON e por um widget web; e e-mail, pelo Mailpit e pelo Action Mailbox;
- **descobre a marca** de cada mensagem, pelo número de WhatsApp ou pelo e-mail de suporte que a recebeu, ou pela marca indicada no chat;
- **reconhece o lojista**, com uma identidade normalizada por canal, e o mesmo lojista em canais diferentes cai na mesma conversa;
- **abre, reabre ou fecha a conversa** conforme o prazo de reabertura da marca;
- **grava a mensagem** pelo caminho único de entrada, com auditoria;
- **entrega as respostas** da IA e dos analistas ao lojista, no mesmo canal e pelo mesmo número ou e-mail que recebeu a mensagem.

Cada canal só traduz o formato dele para um envelope comum, `Channels::InboundMessage`. A partir daí, o caminho é um só para os três: `Conversations::Intake`.

## Onde fica no fluxo

```text
WhatsApp (Meta) ── POST assinado ──────────────┐
Chat (widget ou app) ── POST ──────────────────┼─→ adaptador do canal ─→ Channels::InboundMessage
E-mail: SMTP → Mailpit → webhook → IngestJob → Action Mailbox → SupportMailbox ┘
                                                                                ↓
                                                     Conversations::Intake (uma transação)
                         lojista → conversa → roteamento → mensagem → audit_events → job de webhook

resposta da IA ou do analista → Conversations::Outbound.append! → Channels::DeliveryJob
     → WhatsApp: POST à Cloud API   → E-mail: SMTP   → Chat: Turbo Stream pelo Action Cable
```

## Por que existe e que valor gera

**Um caminho único para três canais.** Autenticação e formato ficam em cada adaptador; identidade, conversa, roteamento, auditoria e webhook ficam no Intake. Uma regra de negócio vale igual em todos os canais, e um canal novo exige só um adaptador.

**O lojista é um só, qualquer que seja o canal.** O lojista que escreve pelo WhatsApp e depois por e-mail é reconhecido pelas identidades do cadastro e continua na mesma conversa, com o histórico inteiro. A IA e o analista veem a história completa, sem pedir ao lojista que repita o problema.

**Multi-marca desde a primeira linha.** A marca de cada mensagem é descoberta pelo número ou pelo e-mail que a recebeu, antes de qualquer acesso ao domínio. Daí em diante, tudo roda dentro do Row-Level Security da marca, e a mesma identidade pode existir nas duas marcas sem que uma veja a outra.

**Nenhuma mensagem duplicada na entrada.** Provedores reenviam webhooks. O id externo de cada mensagem (`wamid`, `client_message_id`, `Message-ID`) é único por marca e canal: o reenvio recebe sucesso e não produz efeito.

**Respostas que não se perdem.** A resposta é gravada e o job de entrega é enfileirado na mesma transação. Falhas transitórias do canal têm novas tentativas, e o horário da entrega fica registrado em `message.delivered`.

**Formatos reais.** WhatsApp segue o formato da Cloud API, com a mesma assinatura e a mesma verificação; e-mail é e-mail de verdade, por SMTP, com `In-Reply-To` e `References`. O sistema troca o simulador por um provedor real sem mudar a lógica de domínio.

## Como funciona

### Marca de cada mensagem

A tabela `brand_channels` guarda os números de WhatsApp e os e-mails de suporte de cada marca. Ela fica fora do RLS, como `brands`, porque a marca precisa ser descoberta antes de `Tenancy.with_brand`; a aplicação só tem leitura nela, e os registros vêm das seeds.

| Marca | `phone_number_id` (número exibido) | E-mails de suporte |
| - | - | - |
| InfinitePay | `110000000000001` (`551140000001`), `110000000000002` (`551140000002`) | `suporte@infinitepay.test`, `financeiro@infinitepay.test` |
| JIM | `120000000000001` (`15555550101`), `120000000000002` (`15555550102`) | `support@jim.test`, `payouts@jim.test` |

Os valores são fictícios, no domínio reservado `.test`. No chat, a marca vem no corpo da entrada JSON ou na URL do widget, como em um app por marca.

### Identidade

`Channels::Identity.normalize` deixa cada identidade num formato único, para que a busca case qualquer que seja a origem:

| Canal | Regra | Exemplo |
| - | - | - |
| `whatsapp` | Só dígitos, com `+` na frente | `16505551234` → `+16505551234` |
| `email` | Minúsculas, sem espaços nas pontas | ` Lojista@Example.COM ` → `lojista@example.com` |
| `chat` | Sem espaços nas pontas | ` app-AbC ` → `app-AbC` |

O cadastro de lojistas das seeds faz o papel do cadastro da CloudWalk: cada lojista já tem telefone, e-mail e id do app ligados. Um remetente desconhecido vira um lojista novo, com uma identidade. Não existe união automática por nome ou texto livre: juntar dois lojistas por engano exporia os dados financeiros de um ao outro.

### Intake

`Conversations::Intake` recebe uma ou mais mensagens da mesma marca e grava todas em uma transação, dentro de `Tenancy.with_brand`. Para cada mensagem:

1. **Reenvio.** Com o `external_id` já gravado na marca e no canal, devolve a mensagem existente, sem novo efeito.
2. **Lojista.** Busca a identidade; sem ela, cria o `Contact`, com o nome que o canal informa (ou a própria identidade) e o idioma da marca (`contact.created`).
3. **Conversa.** Busca a conversa não `closed` do lojista, com `FOR UPDATE`:
   - nenhuma: abre uma, no canal da mensagem (`conversation.opened`);
   - `resolved` dentro do prazo de reabertura: volta a `triage` (`conversation.reopened`) e, na mesma transação, a memória do lojista é recalculada sem ela (`Conversations::MemoryRefresh`, `documents/fases/13-memoria-e-contexto.md`);
   - `resolved` com o prazo vencido: vai a `closed` (`conversation.closed`) e abre outra;
   - qualquer outro estado: usa a conversa.
4. **Roteamento.** Com a conversa em `triage`, classifica e roteia por `Routing::Route` (`documents/fases/07-triagem-roteamento-e-distribuicao.md`).
5. **Mensagem.** Grava a mensagem com a próxima sequência (`message.created`), com o job de webhook ao Broker só se a conversa está com a IA.

O `message.created` leva no `payload.message` o formato do contrato (`author`, `channel`, `text`). O `audit_event` guarda também o id externo, os anexos, a identidade que escreveu e, no e-mail, o assunto: é deles que a entrega lê o destinatário, o assunto e o `In-Reply-To` da resposta.

**Uma conversa por lojista.** Um índice único parcial garante no máximo uma conversa não `closed` por lojista, em qualquer canal. O prazo de reabertura fica em `brands.reopen_window_minutes` (padrão 1440, 24 horas): dentro dele, o lojista que volta continua a mesma conversa; depois dele, começa outra. O prazo é conferido na entrada e também por uma varredura recorrente (`Conversations::CloseExpiredJob`, a cada minuto), que fecha as conversas vencidas em lotes de 100 com `FOR UPDATE SKIP LOCKED`.

**Primeiras mensagens simultâneas.** Duas primeiras mensagens do mesmo lojista ao mesmo tempo batem nos índices únicos (identidade, conversa aberta, `external_id`). A transação que perde é desfeita inteira e tentada de novo, até 3 vezes, e na nova tentativa encontra o que a outra criou. A nova tentativa fica fora do `Tenancy.with_brand`, porque no PostgreSQL a transação com erro fica abortada.

**Mensagem sem texto.** O texto é o texto padrão do primeiro anexo, no idioma da marca: `[imagem enviada]`, `[documento enviado]`, `[áudio enviado]`, `[vídeo enviado]` ou `[conteúdo enviado]`; em inglês, `[image sent]`, `[document sent]`, `[audio sent]`, `[video sent]` ou `[content sent]`. Os anexos são guardados só como metadados (`kind`, `filename`, `content_type` e `size`), sem o arquivo.

### WhatsApp

| Rota | Comportamento |
| - | - |
| `GET /channels/whatsapp/webhook` | Verificação da Meta: com `hub.mode` igual a `subscribe` e `hub.verify_token` igual a `WHATSAPP_VERIFY_TOKEN` (comparação em tempo constante), responde 200 com o `hub.challenge`; senão, 403 |
| `POST /channels/whatsapp/webhook` | Confere `X-Hub-Signature-256` (`sha256=` e o HMAC-SHA256 do corpo bruto com `WHATSAPP_APP_SECRET`); sem assinatura válida, 401; corpo que não é um objeto JSON, 400. As mensagens vão ao Intake em uma transação por marca, e o 200 sai depois do commit |

`Channels::Whatsapp::Payload` percorre `entry[].changes[]` com `field` igual a `messages`:

- a marca vem de `value.metadata.phone_number_id`; número desconhecido é ignorado com log e recebe 200, porque a Meta reenviaria uma resposta de erro sem fim;
- o nome do lojista vem de `value.contacts[]`, casando `wa_id` com `messages[].from`;
- `text` traz o texto em `text.body`; `image`, `document`, `audio` e `video` viram anexo, com o texto da legenda ou o texto padrão; outros tipos viram anexo `other`;
- o `external_id` é o `wamid`; mensagem sem `from` é ignorada com log; `value.statuses` é ignorado.

### Chat

**Entrada JSON**, usada pelo simulador de canais e pela carga: `POST /channels/chat/messages`.

```json
{ "brand": "infinitepay", "app_user_id": "app-…", "client_message_id": "…", "text": "…",
  "attachments": [ { "kind": "image", "filename": "…", "content_type": "…", "size": 123 } ] }
```

- A chamada é assinada com `CHAT_SIGNING_SECRET`, no esquema HMAC com timestamp do contrato; sem assinatura válida, 401.
- JSON inválido, marca desconhecida, `app_user_id` ou `client_message_id` vazios, anexo sem `kind` válido ou mensagem sem texto e sem anexo: 422.
- A resposta 200 traz `conversation_id`, `sequence` e `stream`, o nome assinado do stream Turbo do lojista. O reenvio do mesmo `client_message_id` devolve a mesma resposta.

**Widget** (Hotwire), com login simulado por marca:

| Rota | Função |
| - | - |
| `GET /chat/:brand` | Lista os lojistas da marca com identidade de chat |
| `POST /chat/:brand/session` | Grava o lojista escolhido na sessão |
| `GET /chat/:brand/conversation` | Histórico da conversa aberta, com o canal de cada mensagem, e inscrição no stream do lojista |
| `POST /chat/:brand/messages` | Envio pelo formulário, com CSRF e `client_message_id` gerado no navegador (`crypto.randomUUID()`) |

O stream é por lojista, não por conversa: o widget continua inscrito quando uma conversa nova é aberta. O widget não tem upload de arquivos. O Action Cable atende em `/cable`, sobre o Solid Cable.

### E-mail

1. **Chegada.** O e-mail chega por SMTP ao Mailpit.
2. **Webhook.** O Mailpit faz `POST` do resumo da mensagem a `/channels/email/mailpit`, com basic auth na URL. O endpoint lê só o `ID`, enfileira `Channels::Email::IngestJob` e responde 200; sem credencial válida, 401; sem `ID`, 422.
3. **`IngestJob`.** Baixa o original pela API do Mailpit e confere os destinatários (To e Cc) e o remetente contra `brand_channels`:
   - algum destinatário é e-mail de suporte e o remetente não é: cria o `InboundEmail` do Action Mailbox e marca a mensagem no Mailpit com a tag `cloudesk-ingested`;
   - caso contrário, inclusive a resposta do próprio Core ao lojista: marca a tag `cloudesk-ignored` e não cria nada. É esse filtro que impede as respostas do Core de voltarem como entrada.
4. **Roteamento.** O Action Mailbox manda todo e-mail ao `SupportMailbox`, pela fila `action_mailbox_routing`.
5. **`SupportMailbox`.** A marca é a do primeiro destinatário (To, depois Cc) presente em `brand_channels`; sem nenhum, ou sem remetente, o e-mail é marcado `bounced`, sem envio de resposta. A identidade é o endereço do From; o nome, o nome de exibição do From ou a parte local do endereço; o `external_id`, o `Message-ID`. O texto é a parte `text/plain`, ou o HTML sem tags, sem as linhas citadas (`>`) e sem tudo a partir de uma linha "On … wrote:" ou "Em … escreveu:".
6. **Varredura.** `Channels::Email::SweepJob`, a cada minuto, busca no Mailpit as mensagens sem tag e enfileira um `IngestJob` para cada uma. Como toda mensagem tratada recebe tag, a varredura recupera só o que o webhook perdeu: o Mailpit não reenvia webhooks com falha.

O índice único do Action Mailbox em (`message_id`, `message_checksum`) impede o mesmo e-mail duas vezes, mesmo que o webhook e a varredura o tragam juntos.

### Saída

`Conversations::Outbound.append!` é o caminho único das respostas, para os autores `ai`, `analyst` e `system`:

- acha a mensagem respondida pela sequência; o canal e o número ou e-mail da marca vêm dela, e a resposta sai por onde a mensagem chegou;
- grava a mensagem com `message.created` (sem webhook ao Broker) e enfileira `Channels::DeliveryJob` na mesma transação.

| Canal | Entrega |
| - | - |
| WhatsApp | `POST {WHATSAPP_API_URL}/{phone_number_id}/messages` com `Authorization: Bearer`, no formato de envio da Cloud API (`messaging_product`, `recipient_type`, `to`, `type: "text"`, `text.body`), com os headers `X-Cloudesk-Message-Id` e `traceparent` |
| E-mail | `Channels::ReplyMailer` por SMTP: From o e-mail de suporte que recebeu, To o lojista, assunto `Re: ` mais o assunto do último e-mail do lojista na conversa, `In-Reply-To` e `References` com o `Message-ID` desse e-mail, e o header `X-Cloudesk-Message-Id` |
| Chat | `Turbo::StreamsChannel.broadcast_append_to` no stream do lojista, com o HTML da mensagem |

- No WhatsApp, 2xx é sucesso; 5xx e erro de rede geram nova tentativa; os demais status são permanentes e o job vai para a fila de falhas. No e-mail, erros de conexão e de servidor ocupado geram nova tentativa.
- As novas tentativas usam o backoff exponencial com jitter do projeto (`2^n` segundos mais até 15%), com 10 tentativas.
- Depois da entrega, o job grava `message.delivered` com o canal e o horário.
- A entrega é at-least-once: uma queda entre o envio e a gravação de `message.delivered` repete o envio. O id da mensagem do Core segue em cada entrega, no header `X-Cloudesk-Message-Id` e no HTML do chat, e a repetição é detectável por quem recebe.

## O que o sistema garante

- Toda mensagem de entrada, de qualquer canal, passa pelo mesmo caminho e é gravada com auditoria na mesma transação do lojista, da conversa e do roteamento.
- Toda mensagem é atribuída à marca do número ou do e-mail que a recebeu, e nenhuma escrita acontece fora dessa marca. Uma requisição de WhatsApp com mensagens das duas marcas lê, em cada marca, só as linhas dela, mesmo com o query cache ligado.
- O reenvio de uma mensagem pelo provedor não produz efeito.
- Cada lojista tem no máximo uma conversa não `closed`, e o mesmo lojista em canais diferentes continua na mesma conversa.
- Toda resposta é gravada junto com o job de entrega e sai pelo canal, número ou e-mail por onde a mensagem chegou.
- Toda entrega concluída deixa `message.delivered` com o horário.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Recebimento multicanal simulado: chat, WhatsApp (Cloud API) e e-mail (Mailpit) | As três entradas, a descoberta da marca e o caminho único de entrada | Simulador no papel do lojista e da Meta (F5) |
| Interface de conversa entre cliente e atendente (IA ou analista) | O widget de chat com o histórico e as respostas em tempo real, e a entrega das respostas nos três canais | Painel do analista (F11) |
| Memória e contexto entre interações (conversa, lojista e entre canais) | Identidade unificada por lojista e uma conversa só entre canais, com reabertura dentro do prazo | Contexto ao agente (F8) e memória do lojista entre conversas (F12) |
| Integração com o atendente por webhooks e broker | A gravação da mensagem com o job de webhook na mesma transação | Roteamento (F6), envio do webhook (F7) e Broker (F9) |
| Rastreabilidade e auditoria | Eventos de lojista, conversa, mensagem e entrega, com o `traceparent` da requisição | Linha do tempo (F14) |
| Multi-marca | `brand_channels`, marca descoberta antes do domínio, identidades por marca | RLS e papéis (F1) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · 250 msg/s por 15 min | As entradas de WhatsApp e chat recebem a carga do k6; a transação do Intake é o trabalho por mensagem no `web` |
| H2 · entrada → Kafka com p95 < 300 ms | O `received_at` da requisição, gravado no `message.created`, é o início da medida |
| H3 · nada perdido nem duplicado | O `external_id` único barra o reenvio na entrada; o id da mensagem do Core na entrega permite detectar a resposta repetida |
| H4 · ponta a ponta com p95 < 1 s | O `message.delivered` tem o horário da entrega, que é o fim da medida |

## Diferenciais

Nenhum diferencial é implementado aqui. Esta parte fornece o que eles usam: as mensagens que passam pelo roteamento do "Por que caiu aqui?", as conversas que chegam ao agente com os modos de falha e ao analista com o briefing de handoff, e os horários de entrada e entrega que alimentam o cockpit.

## Limitações

- **Entrega at-least-once.** Uma queda entre o envio ao canal e a gravação de `message.delivered` repete o envio. A repetição é detectável pelo id da mensagem, mas chega ao lojista.
- **Sem união de contatos.** Um lojista que escreve de um telefone ou e-mail fora do cadastro vira um contato novo, com outra conversa.
- **Identificação no WhatsApp.** A Meta indica que `messages[].from` pode faltar quando o usuário usa nome de usuário, com `from_user_id` como identificador. A mensagem sem `from` é ignorada com log.
- **Fidelidade à Cloud API.** Os campos de áudio e vídeo, o `text.body` no envio e o formato da assinatura e da verificação vêm de fontes de terceiros consistentes, não da documentação oficial. Eles afetam só a fidelidade ao formato real; o simulador produz e consome os mesmos formatos.
- **Horário do e-mail.** O `received_at` do e-mail é a criação do `InboundEmail`, posterior à chegada no Mailpit. O e-mail fica fora da carga do experimento.
- **Anexos só como metadados.** O conteúdo dos anexos não é guardado nem repassado ao agente, e o widget não tem upload.
- **Tabelas sem RLS.** `brand_channels` e as tabelas do Active Storage e do Action Mailbox não têm isolamento por marca no banco. `brand_channels` é só leitura para a aplicação, e o e-mail original fica acessível só pelo código do Core.
- **Incineração do e-mail.** O Action Mailbox apaga o `InboundEmail` processado depois de 30 dias. A resposta lê assunto e `Message-ID` do `audit_event`, que é permanente.

## Evolução

- **Verificação de identidade.** Para unir com segurança dois contatos que o cadastro não liga, o sistema envia um código ao telefone ou ao e-mail cadastrado, e o lojista confirma.
- **União manual de contatos.** O analista une dois contatos do mesmo lojista, por exemplo um WhatsApp e um e-mail que o cadastro não liga, e a união gera `audit_event`.

## Operação

### Configuração

| Variável | Uso |
| - | - |
| `WHATSAPP_APP_SECRET` | Assinatura `X-Hub-Signature-256` da entrada |
| `WHATSAPP_VERIFY_TOKEN` | Verificação `GET` do webhook |
| `WHATSAPP_ACCESS_TOKEN` | Bearer do envio |
| `WHATSAPP_API_URL` | Base do envio, com o segmento de versão; aponta para o simulador de canais |
| `CHAT_SIGNING_SECRET` | Assinatura da entrada JSON do chat |
| `MAILPIT_WEBHOOK_USER`, `MAILPIT_WEBHOOK_PASSWORD` | Basic auth do webhook do Mailpit |
| `MAILPIT_API_URL` | API do Mailpit (`http://mailpit:8025`) |
| `SMTP_HOST`, `SMTP_PORT` | SMTP do Mailpit (`mailpit`, `1025`) |

Os segredos têm valor de demonstração no `.env.example`, só para uso local com dados sintéticos, e são trocados fora dele, por exemplo com `openssl rand -hex 32`; não existe conta na Meta nem custo.

- O serviço `mailpit` do Compose recebe `MP_WEBHOOK_URL`, com o basic auth na URL, e `MP_WEBHOOK_LIMIT=0`, que desliga o limite padrão de uma chamada por segundo do webhook.
- Em desenvolvimento, o Action Mailer envia por SMTP ao Mailpit, e `config.hosts` inclui `web`, porque o Mailpit chama o Core pelo nome do serviço.
- O `config/application.rb` fixa as filas `action_mailbox_routing` e `action_mailbox_incineration`, que os defaults do Rails deixariam vazias.
- A entrega roda na fila `channels` e a ingestão de e-mail e as varreduras na fila `default`, no processo `jobs-default` (`documents/fases/08-saida-core-broker.md`). As tarefas `close_expired_conversations` e `sweep_mailpit` estão em `config/recurring.yml`, a cada minuto.

### Banco

| Item | Definição |
| - | - |
| `brand_channels` | `brand_id`, `channel` (`whatsapp` ou `email`), `value` (`phone_number_id` ou e-mail normalizado) e `display_value`; índice único em `(channel, value)`; fora do RLS e só leitura para a aplicação |
| `brands.reopen_window_minutes` | Inteiro positivo, padrão 1440 |
| `messages.external_id` | Índice único parcial em `(brand_id, channel, external_id)` quando não nulo |
| `messages.attachments` | `jsonb`, lista de metadados |
| `messages.brand_channel_id` | Número ou e-mail da marca que recebeu ou enviou; chave estrangeira composta com `brand_id`, que impede apontar para o canal de outra marca |
| `conversations` | Índice único parcial em `(brand_id, contact_id)` com `state <> 'closed'`; índice parcial em `(brand_id, resolved_at)` das conversas `resolved`, para a varredura do prazo |
| Active Storage e Action Mailbox | Tabelas das gems, com chave primária `bigint`, sem `brand_id` e sem RLS; nenhuma tabela de domínio aponta para elas |

### Arquivos principais

| Arquivo | Conteúdo |
| - | - |
| `core/app/modules/conversations/intake.rb` | Caminho único de entrada |
| `core/app/modules/conversations/outbound.rb` | Gravação da resposta e enfileiramento da entrega |
| `core/app/modules/conversations/close_expired_job.rb` | Varredura do prazo de reabertura |
| `core/app/modules/channels/inbound_message.rb`, `identity.rb`, `attachment_text.rb` | Envelope de entrada, normalização das identidades e texto padrão dos anexos |
| `core/app/modules/channels/whatsapp/` | Assinatura, leitura do payload e envio do WhatsApp |
| `core/app/modules/channels/chat.rb` | Stream Turbo do lojista |
| `core/app/modules/channels/email/`, `mailpit/client.rb` | `IngestJob`, `SweepJob` e cliente da API do Mailpit |
| `core/app/modules/channels/delivery_job.rb` | Entrega das respostas |
| `core/app/controllers/channels/` | Webhook do WhatsApp, entrada JSON do chat, widget e webhook do Mailpit |
| `core/app/mailboxes/support_mailbox.rb` | Leitura do e-mail de suporte |
| `core/app/mailers/channels/reply_mailer.rb` | Resposta por e-mail |

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/models/channel_schema_spec.rb` | `brand_channels` visível sem marca e só leitura; uma conversa aberta por lojista; `external_id` único; chave estrangeira de `brand_channel_id`; formato dos anexos; permissões das tabelas das gems; normalização |
| `core/spec/modules/conversations/intake_spec.rb` | Abertura, reabertura, fechamento e nova conversa depois do prazo; reenvio sem efeito; lojista desconhecido; o mesmo lojista em WhatsApp e e-mail como um contato e uma conversa; job de webhook; texto padrão; corrida entre duas primeiras mensagens |
| `core/spec/requests/channels/whatsapp_webhooks_spec.rb` | Verificação `GET`; assinatura válida, inválida e ausente; texto, imagem, documento, tipo sem suporte, statuses, número desconhecido, várias mensagens e reenvio |
| `core/spec/requests/channels/chat_messages_spec.rb` | Assinatura válida, inválida, vencida e ausente; resposta com `stream`; reenvio; anexos; 422 |
| `core/spec/requests/channels/chat_widget_spec.rb` | Lista de lojistas, sessão, envio pelo formulário e histórico com o canal de cada mensagem |
| `core/spec/requests/channels/mailpit_webhooks_spec.rb` | Webhook com e sem basic auth |
| `core/spec/modules/channels/email/ingest_job_spec.rb` | E-mail de suporte vira `InboundEmail` com tag; Cc; resposta do Core e e-mail sem suporte ignorados; nova tentativa; o mesmo e-mail duas vezes |
| `core/spec/modules/channels/email/sweep_job_spec.rb` | Mensagens sem tag geram `IngestJob`, com paginação |
| `core/spec/mailboxes/support_mailbox_spec.rb` | Texto, trecho citado, HTML sem parte de texto, anexos, lojista novo, destinatário sem marca |
| `core/spec/modules/channels/delivery_job_spec.rb` | Saída nos três canais, novas tentativas e falhas permanentes no WhatsApp, cabeçalhos do e-mail, `message.delivered` e resposta no canal da mensagem respondida |
| `core/spec/modules/conversations/close_expired_job_spec.rb` | Fecha só as conversas vencidas, com o prazo de cada marca |
| `core/spec/tenancy/brand_isolation_spec.rb` | Marca do bloco externo mantida depois de blocos aninhados e leitura de cada marca com o query cache ligado: marcas em sequência, sem marca seguida de marca, bloco aninhado, bloco com erro e cache mantido na mesma marca |

No Compose, com `web`, `jobs-default`, `mailpit` e o simulador de canais, uma mensagem de WhatsApp assinada, uma do chat e um e-mail por SMTP do mesmo lojista das seeds viram três mensagens na mesma conversa, cada uma com `message.created`; a resposta por e-mail volta ao Mailpit e recebe a tag `cloudesk-ignored`.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco multi-marca (F1) | Entidades, RLS e `Tenancy.with_brand`, que lê e grava a marca sem o query cache e limpa o query cache na troca de marca |
| Núcleo transacional e auditoria (F2) | Toda escrita passa pelo `Audit::Command`, que grava o evento e enfileira o webhook |
| Contrato (F3) | O `message.created` segue o formato do contrato; a entrada do chat usa a assinatura do contrato |
| Simulador de canais (F5) | Faz o papel do lojista, da Meta e do cliente de e-mail, e recebe as entregas |
| Roteamento (F6) | O Intake chama o roteamento para a conversa em `triage` e condiciona o webhook a `with_ai` |
| Saída para o Broker (F7) | Envia o webhook gravado pelo Intake |
| API de ações (F8) | A ação `reply` responde por `Conversations::Outbound.append!` |
| Handoff e painel (F11) | O analista responde pelo mesmo serviço, com autor `analyst` |
| Experimento (F18) | O k6 chama as entradas de WhatsApp e chat; o `message.delivered` fecha a medida da H4 |

## Fontes

- `documents/arquitetura.md`, seções "Modelo de domínio", "Memória e contexto" e "Componentes simulados"
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
