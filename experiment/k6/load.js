// Carga do experimento: modelo aberto (taxa de chegada constante), sem reenvio.
//
// | Variável | Uso |
// | - | - |
// | RATE, DURATION | Mensagens por segundo e duração (ex.: 300s) |
// | SESSION, RUN | Sessão e execução (ex.: escada-8-1), que formam os ids |
// | STAGE_NUMBER | Número da execução no ambiente, nos telefones do WhatsApp |
// | OUT_DIR | Pasta do k6-summary.json |
//
// Cada iteração grava uma linha JSON com console.log; com --log-format raw e --console-output, o
// arquivo é o sent.jsonl.

import exec from "k6/execution";
import { record, send } from "./lib/clients.js";
import { text } from "./lib/corpus.js";
import { assign } from "./lib/lanes.js";

const RATE = Number(__ENV.RATE);
const CONTEXT = {
  rate: RATE,
  session: __ENV.SESSION,
  run: __ENV.RUN,
  stageNumber: Number(__ENV.STAGE_NUMBER),
};

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"],
  scenarios: {
    load: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: __ENV.DURATION,
      preAllocatedVUs: Math.max(20, RATE),
      maxVUs: 2 * Math.max(20, RATE),
    },
  },
};

export default function () {
  const message = assign(exec.scenario.iterationInTest, CONTEXT);
  const body = text(message.brand, message.lane, message.turn, message.step);
  const sentAt = new Date();
  record(CONTEXT.run, message, sentAt, send(message, body));
}

export function handleSummary(data) {
  return { [`${__ENV.OUT_DIR}/k6-summary.json`]: JSON.stringify(data, null, 2) };
}
