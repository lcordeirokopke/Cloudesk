// Aquecimento do ambiente, fora da medida.
//
// | Variável | Uso |
// | - | - |
// | PHASE | register: cada lojista de chat envia a saudação e registra o stream no simulador; second: cada um envia a saudação de novo, e o WhatsApp recebe 5 msg/s por 30 s |
// | SHOPPERS | Lojistas de chat |
// | SESSION, RUN | Sessão e execução (ex.: aquecimento-1), que formam os ids |
// | STAGE_NUMBER | Número da execução no ambiente, nos telefones do WhatsApp |

import { check } from "k6";
import exec from "k6/execution";
import { record, registerStream, sendChat, sendWhatsapp } from "./lib/clients.js";
import { greeting } from "./lib/corpus.js";
import { chatShopper, numberIndex, phone } from "./lib/lanes.js";

const CHAT_RATE = 10;
const WHATSAPP_RATE = 5;
const WHATSAPP_SECONDS = 30;
const SHOPPERS = Number(__ENV.SHOPPERS);
const SESSION = __ENV.SESSION;
const RUN = __ENV.RUN;
const STAGE_NUMBER = Number(__ENV.STAGE_NUMBER);
const REGISTER = __ENV.PHASE === "register";

const scenarios = {
  chat: {
    executor: "constant-arrival-rate",
    exec: "chat",
    rate: CHAT_RATE,
    timeUnit: "1s",
    duration: `${Math.ceil(SHOPPERS / CHAT_RATE) + 1}s`,
    preAllocatedVUs: 20,
    maxVUs: 60,
  },
};
if (!REGISTER) {
  scenarios.whatsapp = {
    executor: "constant-arrival-rate",
    exec: "whatsapp",
    rate: WHATSAPP_RATE,
    timeUnit: "1s",
    duration: `${WHATSAPP_SECONDS}s`,
    preAllocatedVUs: 20,
    maxVUs: 40,
  };
}

export const options = { discardResponseBodies: true, scenarios: scenarios };

export function chat() {
  const index = exec.scenario.iterationInTest;
  if (index >= SHOPPERS) return;

  const shopper = chatShopper(SESSION, index);
  const message = {
    i: index, lane: index, conv: 0, step: 0, channel: "chat", brand: shopper.brand, appUserId: shopper.appUserId,
    externalId: `exp-${SESSION}-${RUN}-chat-${index}`,
  };
  const sentAt = new Date();
  const response = sendChat(message, greeting(shopper.brand));
  record(RUN, message, sentAt, response);
  const accepted = check(response, { "chat aceito": (r) => r.status === 200 });
  if (REGISTER && accepted) {
    check(registerStream(response.json("stream"), shopper.appUserId), { "stream registrado": (r) => r.status === 200 });
  }
}

export function whatsapp() {
  const index = exec.scenario.iterationInTest;
  const brand = chatShopper(SESSION, index).brand;
  const message = {
    i: index, lane: index, conv: 0, step: 0, channel: "whatsapp", brand: brand, numberIndex: numberIndex(index),
    from: phone(brand, STAGE_NUMBER, index, 0), externalId: `wamid.exp-${SESSION}-${RUN}-whatsapp-${index}`,
  };
  const sentAt = new Date();
  const response = sendWhatsapp(message, greeting(brand));
  record(RUN, message, sentAt, response);
  check(response, { "whatsapp aceito": (r) => r.status === 200 });
}
