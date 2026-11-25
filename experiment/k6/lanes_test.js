// Teste das faixas e dos textos, sem rede: uma iteração, com check.
//   k6 run --iterations 1 /scripts/lanes_test.js

import { check } from "k6";
import { text, THANKS_STEP } from "./lib/corpus.js";
import { assign, chatShopper, PAUSE_SECONDS, rand, STEPS } from "./lib/lanes.js";

export const options = { vus: 1, thresholds: { checks: ["rate==1"] } };

const CONTEXT = { rate: 250, session: "20261201T100000Z", run: "meta-1", stageNumber: 7 };
const DURATION = 900;

export default function () {
  const lanes = CONTEXT.rate * PAUSE_SECONDS;
  const turns = DURATION / PAUSE_SECONDS;
  const messages = [];
  for (let i = 0; i < lanes * turns; i += 1) messages.push(assign(i, CONTEXT));

  const byLane = {};
  for (const message of messages) {
    if (!byLane[message.lane]) byLane[message.lane] = [];
    byLane[message.lane].push(message);
  }
  const laneList = Object.values(byLane);
  const pairs = laneList.flatMap((list) => list.slice(1).map((message, index) => [list[index], message]));
  const first = laneList.map((list) => list[0]);
  const chat = first.filter((message) => message.channel === "chat");
  const infinitepay = first.filter((message) => message.brand === "infinitepay").length / first.length;

  check(null, {
    "faixas ativas: taxa vezes a pausa": () => laneList.length === lanes,
    "passos em ordem dentro da conversa": () =>
      pairs.every(([a, b]) => (a.step === STEPS - 1 ? b.step === 0 && b.conv === a.conv + 1 : b.step === a.step + 1 && b.conv === a.conv)),
    "toda conversa completa tem os passos 0 a 4": () =>
      laneList.every((list) => list.filter((m) => m.conv === 1).map((m) => m.step).join("") === "01234"),
    "primeiros passos desencontrados": () => new Set(first.map((message) => message.step)).size === STEPS,
    "pausa de 20 s entre passos da faixa": () => pairs.every(([a, b]) => (b.i - a.i) / CONTEXT.rate === PAUSE_SECONDS),
    "10% de chat": () => chat.length === lanes / 10 && chat.length === 500,
    "cerca de 70% de infinitepay": () => infinitepay > 0.67 && infinitepay < 0.73,
    "marca do chat também perto de 70%": () => {
      const share = chat.filter((message) => message.brand === "infinitepay").length / chat.length;
      return share > 0.6 && share < 0.8;
    },
    "canal e marca fixos por faixa": () =>
      laneList.every((list) => new Set(list.map((m) => `${m.channel}:${m.brand}:${m.appUserId}`)).size === 1),
    "marca do lojista de chat igual em outra taxa": () =>
      [0, 10, 150].every((i) => assign(i, Object.assign({}, CONTEXT, { rate: 8 })).brand === chatShopper(CONTEXT.session, i / 10).brand),
    "ids externos únicos": () => new Set(messages.map((message) => message.externalId)).size === messages.length,
    "telefone único por conversa": () => {
      const whatsapp = messages.filter((message) => message.channel === "whatsapp");
      const conversations = new Set(whatsapp.map((message) => `${message.lane}:${message.conv}`));
      return new Set(whatsapp.map((message) => message.from)).size === conversations.size;
    },
    "telefone com 13 dígitos na infinitepay e 11 na jim": () =>
      messages.every((m) => m.channel === "chat" || m.from.length === (m.brand === "infinitepay" ? 13 : 11)),
    "telefones de execuções diferentes não se repetem": () => {
      const other = assign(1, Object.assign({}, CONTEXT, { stageNumber: 8 }));
      return other.from !== assign(1, CONTEXT).from;
    },
    "mesma iteração, mesma mensagem": () => JSON.stringify(assign(1234, CONTEXT)) === JSON.stringify(assign(1234, CONTEXT)),
    "sais sem correlação": () => {
      let equal = 0;
      for (let lane = 0; lane < 1000; lane += 1) if (rand(lane, 1) < 0.5 === rand(lane, 2) < 0.5) equal += 1;
      return equal > 400 && equal < 600;
    },
    "passo 4 é o agradecimento": () =>
      messages.slice(0, 5000).every((m) => /^(Obrigado|Thank you)/.test(text(m.brand, m.lane, m.turn, m.step)) === (m.step === THANKS_STEP)),
    "quatro perguntas diferentes na conversa": () =>
      laneList.slice(0, 200).every((list) => {
        const subjects = list.filter((m) => m.conv === 1 && m.step !== THANKS_STEP)
          .map((m) => text(m.brand, m.lane, m.turn, m.step).replace(/(TX|SN)\d+/, ""));
        return new Set(subjects).size === 4;
      }),
  });
}
