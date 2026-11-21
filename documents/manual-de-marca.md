# Manual de marca do Cloudesk

O Cloudesk segue a identidade visual da CloudWalk. Este manual descreve essa identidade, derivada do site institucional da CloudWalk, e define como ela se aplica às telas do Cloudesk: widget de chat do lojista, painel do analista e admin de filas e regras.

## 1. Origem e método

A CloudWalk não publica um manual de marca. Este documento é uma proposta derivada do site `https://www.cloudwalk.io/pt`, analisado em três frentes:

- **Navegação:** a página inicial e as páginas do menu (Stratus, Impact, AI, Nimbus, Trabalhe conosco, Redação), percorridas em navegador com rolagem completa, em 1440 px.
- **Estilos computados:** fonte, tamanho, peso, cor, fundo, raio e espaçamento dos elementos visíveis de cada página, lidos no navegador.
- **CSS publicado:** as variáveis de cor declaradas em `:root`, as regras dos componentes (navegação, botões, tags, rodapé) e as fontes carregadas.

Os valores das seções 3 a 6 são os medidos no site. As seções 7 a 9 transpõem essa linguagem para uma ferramenta de trabalho, com tema claro e escuro, densidade de informação maior e as regras de acessibilidade da WCAG 2.2, nível AA.

## 2. Princípios visuais

| Princípio | Como aparece no site | Como se aplica no Cloudesk |
| - | - | - |
| Escuro e monocromático | Fundo `#111111` e `#000000`, texto em off-white `#ecebe9`, painéis de conteúdo em `#181818` | A interface é em tons neutros; a cor entra só para estado, autor da mensagem e foco |
| A cor vem do conteúdo | Fotografia, ilustração e as marcas de produto (InfinitePay, JIM, Pierre) carregam a cor; a interface não | Nenhum botão, link ou cabeçalho é colorido |
| Tipografia geométrica, grande e leve | Cera Pro em 300 nos títulos de seção (46 px) e 500 no título principal (56 px) | Títulos de página em peso leve; o peso 500 marca rótulos e subtítulos |
| Rótulos em caixa alta | Menu, botões e tags em caixa alta, 14 a 16 px, peso 500 | Botões, tags, cabeçalhos de tabela e menu em caixa alta |
| Formas curvas | Botões em pílula (raio 100 px); cartões da página Impact com raio de 24 px; imagens com raio de 1 rem; tags quase retas (raio 2 px) | Botões e campos em pílula, cartões com 24 px, mensagens e avisos com 16 px; só as tags ficam quase retas |
| Espaço generoso | Contêiner de até 1480 px com 32 px de margem; seções com 6 a 8 rem de respiro | Contêiner de até 1480 px com 32 px de margem (16 px no celular) e cartões com 24 px de respiro |

## 3. Logotipo

### 3.1 CloudWalk

O logotipo da CloudWalk combina um símbolo de arcos concêntricos com o nome `cloudwalk` em minúsculas, em peso forte. No site, ele aparece em branco sobre fundo escuro, centralizado no menu e alinhado à esquerda no rodapé. No rodapé, o nome `CLOUDWALK` aparece também em caixa alta, em letras finas e enormes, em cinza escuro sobre o fundo `#131313`.

O logotipo da CloudWalk é marca registrada e **não é reproduzido no Cloudesk**.

### 3.2 Cloudesk

O Cloudesk se identifica por um wordmark próprio, no mesmo espírito do nome `cloudwalk`:

- texto `cloudesk`, sempre em minúsculas;
- fonte da marca (seção 5), peso 600, 20 px no cabeçalho;
- cor off-white `#ecebe9` sobre o cabeçalho escuro;
- seguido do nome do produto em rótulo (caixa alta, 12 px, peso 500, cinza `#a0a0a0`): `Painel do analista` ou `Admin`.

O favicon (`core/public/icon.svg` e `core/public/icon.png`) é um quadrado escuro `#111111` de cantos arredondados com a letra `c` desenhada como um arco off-white de traço grosso e pontas redondas.

## 4. Cores

### 4.1 Paleta do site

Variáveis declaradas no CSS do site e cores medidas nas páginas:

| Nome no site | Valor | Uso no site |
| - | - | - |
| `black` | `#111111` | Fundo da página e texto sobre superfícies claras |
| preto puro | `#000000` | Fundo do topo e das seções de investidores |
| painel escuro | `#181818` | Fundo dos painéis de texto das marcas |
| rodapé | `#131313` | Fundo do rodapé |
| `main-white` | `#ecebe9` | Texto principal sobre fundo escuro |
| botão claro | `#ebebeb` | Fundo do botão principal |
| texto do botão | `#050505` | Texto do botão principal |
| cinza de rodapé | `#a0a0a0` | Links do rodapé |
| `neutral-300` a `neutral-950` | `#bcbcc1`, `#8e8e93`, `#6c6c70`, `#545456`, `#444446`, `#363638`, `#242426`, `#1c1c1e` | Escala de cinzas de texto |
| `m-gray` | `#dadada` | Divisores claros |
| superfície clara | `#f5f5f5` e `#ffffff` | Seções claras da Redação |
| `blue` | `#467afc` | Marcador de "Notícias em destaque" e links de contato |
| `green-terminal` | `#24d332` | Destaque verde (Nimbus) |
| `light-coral` | `#ff667d` | Destaque de alerta |
| `burlywood` | `#f3bf73` | Destaque quente |
| `sienna` | `#b84900` | Laranja escuro |
| `dark-slate-grey-2` | `#1c3a29` | Verde escuro |

### 4.2 Tokens do Cloudesk

Os tokens são propriedades personalizadas de CSS com o prefixo `cw-`, declaradas em `core/app/assets/stylesheets/brand.css`. O tema segue a preferência do sistema (`prefers-color-scheme`): o escuro reproduz o site; o claro usa as superfícies claras da Redação.

| Token | Tema claro | Tema escuro | Uso |
| - | - | - | - |
| `cw-bg` | `#f5f5f5` | `#111111` | Fundo da página |
| `cw-surface` | `#ffffff` | `#181818` | Cartões, tabelas, campos |
| `cw-surface-sunken` | `#f5f5f5` | `#242426` | Mensagem do lojista no painel, áreas rebaixadas |
| `cw-text` | `#111111` | `#ecebe9` | Texto principal |
| `cw-text-muted` | `#6c6c70` | `#a0a0a0` | Texto secundário, metadados, rótulos |
| `cw-border` | `#dadada` | `rgba(244, 242, 232, 0.12)` | Divisores e contorno de cartões |
| `cw-border-input` | `#8e8e93` | `#6c6c70` | Contorno de campos |
| `cw-action-bg` | `#111111` | `#ebebeb` | Fundo do botão principal |
| `cw-action-text` | `#ffffff` | `#050505` | Texto do botão principal |
| `cw-action-hover` | `#363638` | `#ffffff` | Fundo do botão principal sob o cursor |
| `cw-wash` | `rgba(0, 0, 0, 0.06)` | `rgba(255, 255, 255, 0.08)` | Fundo do botão secundário sob o cursor |
| `cw-tag-bg` | `rgba(153, 153, 153, 0.12)` | `rgba(124, 124, 124, 0.12)` | Fundo da tag |
| `cw-tag-text` | `#111111` | `rgba(255, 255, 255, 0.8)` | Texto da tag |
| `cw-focus` | `#467afc` | `#467afc` | Anel de foco |
| `cw-alert` | `#b84900` | `#ff667d` | Erro, SLA estourado, valor fora da lista |
| `cw-alert-bg` | `rgba(184, 73, 0, 0.08)` | `rgba(255, 102, 125, 0.12)` | Fundo de aviso de erro |
| `cw-success` | `#1c3a29` | `#24d332` | Confirmação |
| `cw-success-bg` | `rgba(36, 211, 50, 0.12)` | `rgba(36, 211, 50, 0.12)` | Fundo de aviso de confirmação |

O cabeçalho é escuro nos dois temas, como o menu do site: `cw-header-bg` `#111111`, `cw-header-text` `#ecebe9`, `cw-header-muted` `#a0a0a0`, `cw-header-border` `rgba(244, 242, 232, 0.12)` e `cw-header-wash` `rgba(255, 255, 255, 0.08)` (fundo do botão secundário do cabeçalho sob o cursor).

### 4.3 Cores por autor da mensagem

A conversa distingue os autores por um fundo tingido com uma cor da paleta em baixa opacidade, sempre acompanhado do nome do autor no metadado (a cor nunca é o único sinal).

| Autor | Token | Tema claro | Tema escuro |
| - | - | - | - |
| Lojista (`customer`) | `cw-msg-customer` | `#f5f5f5` | `#242426` |
| IA (`ai`) | `cw-msg-ai` | `#467afc` a 10% | `#467afc` a 16% |
| Analista (`analyst`) | `cw-msg-analyst` | `#24d332` a 12% | `#24d332` a 12% |
| Sistema (`system`) | `cw-msg-system` | `#f3bf73` a 22% | `#f3bf73` a 14% |

No widget de chat, a mensagem do próprio lojista usa as cores do botão principal (`cw-action-bg` e `cw-action-text`) e fica à direita; as respostas ficam à esquerda com as cores da tabela.

### 4.4 Regras de uso

- O azul `#467afc` é reservado ao anel de foco e ao tom da mensagem da IA. Ele não é usado como cor de texto no tema claro, onde o contraste com o branco fica em 3,85:1.
- Links usam a cor do texto, com sublinhado; a espessura do sublinhado aumenta sob o cursor.
- Todo par de texto e fundo dos tokens tem contraste de pelo menos 4,5:1; o contorno dos campos tem pelo menos 3:1 com o fundo.

## 5. Tipografia

### 5.1 Famílias

| Papel | Site | Cloudesk |
| - | - | - |
| Texto e títulos | Cera Pro (100, 300, 400, 500, 700), fonte comercial servida pelo próprio site | `Cera Pro`, quando instalada na máquina, e Gabarito (400 a 900, licença SIL Open Font License) |
| Dados técnicos | IBM Plex Mono (300 a 700) | IBM Plex Mono (400 e 500, licença SIL Open Font License) |

A pilha completa é `"Cera Pro", "Gabarito", system-ui, sans-serif` para o texto e `"IBM Plex Mono", ui-monospace, monospace` para dados. Os arquivos `woff2` da Gabarito e da IBM Plex Mono (subconjunto latino, que cobre o português) ficam em `core/app/assets/fonts`, com as licenças ao lado, e não dependem de serviço externo. A Gabarito não tem peso 300; onde o site usa Cera Pro 300, o Cloudesk usa 400.

### 5.2 Escala do site

| Elemento | Tamanho | Peso | Altura de linha | Caixa |
| - | - | - | - | - |
| Título principal | 56 px | 500 | 1,1 | normal |
| Título de seção | 40 a 46 px | 300 | 1,2 | normal |
| Subtítulo | 24 px | 500 | 30 px | normal |
| Texto corrido | 18 a 20 px | 300 a 500 | 1,55 | normal |
| Menu, botão, tag | 14 a 16 px | 500 | 1,4 | alta |
| Legal e rodapé | 14 a 17,5 px | 400 | 1,55 | normal |

### 5.3 Escala do Cloudesk

| Elemento | Tamanho | Peso | Altura de linha | Caixa |
| - | - | - | - | - |
| Título da página (`h1`) | 2 rem (32 px); 1,5 rem no celular | 400 | 1,2 | normal |
| Título de cartão (`h2`) | 1,25 rem (20 px) | 500 | 1,2 | normal |
| Subtítulo (`h3`) | 1 rem (16 px) | 500 | 1,2 | normal |
| Texto | 1 rem (16 px) | 400 | 1,55 | normal |
| Botão, tag, menu | 0,875 rem (14 px) | 500 | 1 | alta |
| Cabeçalho de tabela, rótulo de produto | 0,75 rem (12 px) | 500 | 1,4 | alta |
| Metadado de mensagem e código | 0,75 a 0,875 rem, IBM Plex Mono | 400 | 1,4 | normal |

### 5.4 Regras

- Títulos e frases em caixa normal, com inicial maiúscula só na primeira palavra e em nomes próprios.
- A caixa alta é aplicada pelo CSS (`text-transform`), e o texto da view segue escrito em caixa normal.
- Números de tabelas, prioridades e durações usam algarismos tabulares (`font-variant-numeric: tabular-nums`).
- Identificadores, nomes de evento, chaves de condição, JSON e sequência de mensagem usam IBM Plex Mono.

## 6. Forma, espaço e profundidade

| Atributo | Site | Cloudesk |
| - | - | - |
| Contêiner | até 1480 px, margem lateral de 32 px | até 1480 px, margem de 32 px; 16 px abaixo de 600 px de largura |
| Espaçamento | passos de 0,25 rem a 8 rem; vãos de 1, 1,5 e 2 rem | passos de 0,25, 0,5, 0,75, 1, 1,5 e 2 rem |
| Raio de pílula | 100 px (botões), 5 rem (barra de marcas) | 100 px (`cw-radius-pill`) para botões e campos de uma linha |
| Raio de tag | 2 px | 2 px |
| Raio de cartão | 24 px (cartões da página Impact); 6 px (cartões da Redação) | 24 px (`cw-radius-card`) para cartões |
| Raio suave | 1 rem (16 px) em imagens | 16 px (`cw-radius-soft`) para mensagens, avisos, área de texto e grupos de campos |
| Bordas | 1 px, translúcidas no escuro (`rgba(244, 242, 232, 0.12)`) e cinza no claro | 1 px com `cw-border` |
| Sombra | nenhuma; profundidade por contraste de superfície e desfoque de fundo | nenhuma |

## 7. Componentes

### 7.1 Cabeçalho

Faixa escura (`cw-header-bg`) com borda inferior `cw-header-border`, altura mínima de 64 px e margem lateral de 32 px (16 px no celular). À esquerda, o wordmark e o nome do produto; em seguida, o menu (admin) em caixa alta 14 px peso 500, sem sublinhado, com a página corrente sublinhada; à direita, o contexto (analista, equipe, marca ou operador) em `cw-header-muted` e o botão secundário de sair.

### 7.2 Botões

| Variante | Fundo | Texto | Borda | Uso |
| - | - | - | - | - |
| Principal | `cw-action-bg` | `cw-action-text` | nenhuma | A ação principal da tela: Entrar, Pegar próximo, Enviar, Salvar, Útil |
| Secundário | transparente | `cw-text` | 1 px na cor do texto | Ações de menor peso: Resolver, Não útil, Desativar, Ativar, Cancelar, Trocar analista |

Forma: pílula (raio 100 px), altura mínima de 44 px, 1,5 rem de respiro lateral, texto em caixa alta 14 px peso 500, sem sublinhado também quando o botão é um link. Sob o cursor, o principal usa `cw-action-hover` e o secundário recebe `cw-wash`. Desabilitado: opacidade 0,4 e cursor de bloqueio.

### 7.3 Links

Cor do texto, sublinhado de 1 px afastado 0,2 em da linha de base; 2 px sob o cursor. Links de navegação do cabeçalho não têm sublinhado.

### 7.4 Tags

Rótulo curto de estado ou valor (estado da conversa, estado da regra, prioridade): caixa alta, 0,75 rem, peso 500, respiro de 0,25 por 0,5 rem, raio 2 px, fundo `cw-tag-bg` e texto `cw-tag-text`. Números em tags usam algarismos tabulares.

### 7.5 Campos

Texto, número, seleção e área de texto: altura mínima de 44 px (área de texto livre), respiro de 0,5 por 1 rem, raio de pílula (100 px) nos campos de uma linha e 16 px na área de texto, borda 1 px `cw-border-input`, fundo `cw-surface`, texto `cw-text` e marcador de exemplo em `cw-text-muted`. Rótulo acima do campo, em 0,875 rem peso 500. Checkbox e radio usam `accent-color` na cor do texto. Grupos de campos (`fieldset`) têm borda `cw-border`, raio 16 px e legenda em rótulo de caixa alta.

### 7.6 Cartões

Fundo `cw-surface`, borda 1 px `cw-border`, raio 24 px, respiro de 1,5 rem, sem sombra; título em `h2`.

### 7.7 Tabelas

Largura total; cabeçalho em rótulo (caixa alta, 12 px, peso 500, `cw-text-muted`); linhas separadas por `cw-border`; respiro de 0,75 rem; números com algarismos tabulares. No celular, a tabela rola na horizontal dentro do cartão.

### 7.8 Mensagens

Bloco com raio 16 px, respiro de 0,75 por 1 rem e fundo conforme o autor (seção 4.3). O metadado (sequência, autor, canal, horário) vem antes do texto, em IBM Plex Mono 0,75 rem e `cw-text-muted`; o texto preserva quebras de linha. No widget de chat, as mensagens ocupam até 85% da largura e alinham pelo autor.

### 7.9 Avisos

Faixa com raio 16 px, respiro de 0,75 por 1 rem e borda de 1 px na cor funcional: erro em `cw-alert` sobre `cw-alert-bg`; confirmação em `cw-success` sobre `cw-success-bg`. Erros de formulário vêm em lista dentro do aviso, com `role="alert"`.

### 7.10 Lista de fatos

Pares rótulo e valor (`dl`) em duas colunas: rótulo em `cw-text-muted`, valor em `cw-text`; vão de 0,375 por 1 rem.

### 7.11 Foco

Todo elemento interativo mostra, no foco por teclado, um anel de 2 px em `cw-focus` afastado 2 px do elemento.

## 8. Tom de voz e microtexto

O site fala em frases curtas e afirmativas, sem exclamação, com títulos em caixa normal e chamadas de ação diretas ("Descubra o InfinitePay", "Saiba mais"). No Cloudesk:

- botões nomeiam a ação com um verbo no infinitivo: Entrar, Enviar, Salvar, Resolver, Pegar próximo;
- mensagens vazias dizem o estado em uma frase ("Nenhuma conversa na fila.");
- textos de apoio explicam a consequência da ação ("Salvar publica a versão 3; a próxima conversa já usa a versão nova.").

## 9. Acessibilidade e movimento

- Contraste mínimo de 4,5:1 para texto e 3:1 para contorno de campos e anel de foco, nos dois temas.
- Alvo de toque mínimo de 44 px em botões e campos.
- O tema acompanha `prefers-color-scheme`; o cabeçalho é escuro nos dois.
- O site usa animações de rolagem; o Cloudesk não anima a interface, e a atualização em tempo real do painel preserva a rolagem.

## 10. Implementação

| Arquivo | Conteúdo |
| - | - |
| `core/app/assets/fonts/` | Gabarito e IBM Plex Mono em `woff2`, com as licenças |
| `core/app/assets/stylesheets/brand.css` | Fontes, tokens dos dois temas, base tipográfica, links, foco, campos, botões, tags e wordmark |
| `core/app/assets/stylesheets/panel.css` | Cabeçalho, contêiner, cartões, tabelas, mensagens e avisos do painel e do admin (`body.panel`) |
| `core/app/assets/stylesheets/admin.css` | Menu, formulários em grade e histórico do admin (`body.admin`) |
| `core/app/assets/stylesheets/chat.css` | Widget de chat do lojista (`.chat`) |
| `core/public/icon.svg`, `core/public/icon.png` | Favicon |

Os estilos de tela usam só os tokens `cw-`; nenhum valor de cor fica fora de `brand.css`.

## 11. Inventário das telas e conferência

Cada tela abaixo é conferida com as seções 2 a 9 nos temas claro e escuro, em 1440 px, e o widget de chat também em 420 px.

| Tela | Fase | Rota | Views | Componentes do manual | Situação |
| - | - | - | - | - | - |
| Chat: escolha do lojista | F4 | `/chat/:brand` | `channels/chat_widget/index` | Cabeçalho do chat, cartão, campo, botão principal | Conforme |
| Chat: conversa | F4 | `/chat/:brand/conversation` | `channels/chat_widget/conversation`, `channels/chat/_message` | Cabeçalho do chat, mensagens alinhadas pelo autor, campo e botão principal | Conforme |
| Painel: entrar | F11 | `/panel` | `panel/sessions/index` | Cabeçalho, cartão, campo, botão principal | Conforme |
| Painel: fila de escalas | F11 | `/panel/queue` | `panel/queues/show` | Cabeçalho, botão principal, tabela, tags de prioridade, SLA estourado em `cw-alert` | Conforme |
| Painel: conversa | F11, F12 | `/panel/conversations/:id` | `panel/conversations/show`, `_message` | Tag de estado, mensagens por autor, área de texto, botões principal e secundário | Conforme |
| Briefing do handoff avaliado (diferencial 1) | F11 | cartão da conversa | `panel/conversations/_handoff_card` | Cartão, lista de fatos, código, botões Útil e Não útil | Conforme |
| Por que caiu aqui? (diferencial 3) | F11 | cartão da conversa | `panel/conversations/_routing_explanation` | Cartão, lista de fatos | Conforme |
| Memória do lojista e conversas anteriores | F12 | cartões da conversa | `panel/conversations/_customer_memory`, `_previous_conversations` | Cartão, mensagens por autor | Conforme |
| Admin: escolher marca | F13 | `/admin` | `admin/sessions/index` | Cabeçalho, cartão, campo, botão principal | Conforme |
| Admin: regras | F13 | `/admin/rules`, `/admin/rules/:id`, `new`, `edit` | `admin/rules/*` | Tabela, tags de estado, código, campos, checkbox e radio, grupos de campos, botões | Conforme |
| Admin: filas | F13 | `/admin/queues` e derivadas | `admin/queues/*` | Tabela, lista de fatos, campos, botões | Conforme |
| Admin: equipes | F13 | `/admin/teams` e derivadas | `admin/teams/*` | Tabela, lista de fatos, campos, checkbox e radio, botões | Conforme |
| Admin: atendentes | F13 | `/admin/attendants` e derivadas | `admin/attendants/*` | Tabela, lista de fatos, campos, botões | Conforme |
| Admin: histórico e erros | F13 | parciais | `admin/shared/_history`, `_errors` | Tabela, código, aviso de erro | Conforme |
