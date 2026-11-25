// Textos da carga, por marca e passo. Todos têm fila inicial da IA para lojista sem segmento, e os ids
// levam as ferramentas do agente a retornos que geram reply: nenhuma mensagem gera escalate.

import { rand, SALT_QUESTION } from "./lanes.js";

export const THANKS_STEP = 4;

const TRANSACTIONS = [
  "TX1000000001", "TX1000000002", "TX1000000004", "TX1000000008",
  "TX1000000009", "TX1000000010", "TX1000000011", "TX1000000012",
];
const SERIALS = [
  "SN10000002", "SN10000003", "SN10000005", "SN10000006",
  "SN10000007", "SN10000008", "SN10000009", "SN10000011",
];

const GREETING = 1;
const TEXTS = {
  infinitepay: {
    questions: [
      () => "Qual a taxa do crédito parcelado em 12x?",
      () => "Oi, tudo bem? Preciso de ajuda.",
      (tx) => `Podem verificar a transação ${tx}? Ela ficou pendente.`,
      (tx, sn) => `A maquininha ${sn} mostra erro de conexão ao passar o cartão.`,
    ],
    thanks: "Obrigado, era isso.",
  },
  jim: {
    questions: [
      () => "What is the fee for credit card installments?",
      () => "Hi, how are you? I need some help.",
      (tx) => `Can you check transaction ${tx}? It has been pending.`,
      (tx, sn) => `Card reader ${sn} shows a connection error when I swipe a card.`,
    ],
    thanks: "Thank you, that is all.",
  },
};

export function greeting(brand) {
  return TEXTS[brand].questions[GREETING]();
}

// O passo 0 sorteia, pela faixa, uma das perguntas; os passos 1 a 3 seguem a lista em rodízio.
export function text(brand, lane, turn, step) {
  if (step === THANKS_STEP) return TEXTS[brand].thanks;

  const questions = TEXTS[brand].questions;
  const first = Math.floor(rand(lane, SALT_QUESTION) * questions.length);
  const tx = TRANSACTIONS[(lane + turn) % TRANSACTIONS.length];
  const sn = SERIALS[(lane + turn) % SERIALS.length];
  return questions[(first + step) % questions.length](tx, sn);
}
