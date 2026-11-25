// Faixas da carga: da iteração do k6 para canal, marca, lojista, conversa e passo.
//
// Para a taxa R e a pausa de 20 s, existem R * 20 faixas ativas. Cada faixa é um lojista em conversa:
// a iteração i atende a faixa i % faixas, então a mesma faixa volta a cada 20 s. Cada conversa tem 5
// mensagens (passos 0 a 4: quatro perguntas e um agradecimento), e o deslocamento inicial da faixa
// desencontra os passos entre as faixas. Tudo é determinístico: a mesma iteração gera a mesma
// mensagem e o mesmo id.
//
// No WhatsApp, o lojista é novo a cada conversa. No chat (uma faixa em cada 10), o lojista é fixo e o
// mesmo em todas as etapas do ambiente, com a marca definida pelo índice dele.

export const PAUSE_SECONDS = 20;
export const STEPS = 5;
export const CHAT_EVERY = 10;
export const INFINITEPAY_SHARE = 0.7;

const SALT_OFFSET = 1;
const SALT_BRAND = 2;
const SALT_NUMBER = 3;
export const SALT_QUESTION = 4;

// mulberry32 com a semente da faixa e do sal: número entre 0 e 1, sem correlação entre os sais.
export function rand(lane, salt) {
  let a = (Math.imul(lane + 1, 0x9e3779b1) ^ Math.imul(salt, 0x85ebca6b)) >>> 0;
  a = (a + 0x6d2b79f5) >>> 0;
  let t = a;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

function digits(value, size) {
  return String(value).padStart(size, "0");
}

export function chatShopper(session, index) {
  return {
    index: index,
    appUserId: `app-exp-${session}-${index}`,
    brand: rand(index, SALT_BRAND) < INFINITEPAY_SHARE ? "infinitepay" : "jim",
  };
}

// Telefone do lojista de WhatsApp: execução do ambiente (2 dígitos), faixa (4) e conversa (2).
export function phone(brand, stageNumber, lane, conv) {
  const suffix = digits(stageNumber, 2) + digits(lane, 4) + digits(conv, 2);
  return (brand === "infinitepay" ? "55119" : "120") + suffix;
}

// Índice do número de WhatsApp da marca (0 ou 1), fixo por faixa.
export function numberIndex(lane) {
  return rand(lane, SALT_NUMBER) < 0.5 ? 0 : 1;
}

// context: { rate, session, run, stageNumber }.
export function assign(i, context) {
  const lanes = context.rate * PAUSE_SECONDS;
  const lane = i % lanes;
  const turn = Math.floor(i / lanes);
  const offset = Math.floor(rand(lane, SALT_OFFSET) * STEPS);
  const step = (turn + offset) % STEPS;
  const conv = Math.floor((turn + offset) / STEPS);
  const base = { i: i, lane: lane, turn: turn, offset: offset, step: step, conv: conv };

  if (lane % CHAT_EVERY === 0) {
    const shopper = chatShopper(context.session, lane / CHAT_EVERY);
    return Object.assign(base, {
      channel: "chat",
      brand: shopper.brand,
      appUserId: shopper.appUserId,
      externalId: `exp-${context.session}-${context.run}-${i}`,
    });
  }

  const brand = rand(lane, SALT_BRAND) < INFINITEPAY_SHARE ? "infinitepay" : "jim";
  return Object.assign(base, {
    channel: "whatsapp",
    brand: brand,
    from: phone(brand, context.stageNumber, lane, conv),
    numberIndex: numberIndex(lane),
    externalId: `wamid.exp-${context.session}-${context.run}-${i}`,
  });
}
