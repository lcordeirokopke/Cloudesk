// Envio às entradas do Core: payload e assinatura de WhatsApp e chat, e registro do stream do chat no
// simulador de canais. Sem reenvio, com timeout de 10 s.

import { hmac } from "k6/crypto";
import http from "k6/http";

const CORE_URL = __ENV.CORE_URL || "http://web-lb:3000";
const SIMULATOR_URL = __ENV.SIMULATOR_URL || "http://channel-simulator:8080";
const WHATSAPP_APP_SECRET = __ENV.WHATSAPP_APP_SECRET || "";
const CHAT_SIGNING_SECRET = __ENV.CHAT_SIGNING_SECRET || "";
const CHAT_PATH = "/channels/chat/messages";
const TIMEOUT = "10s";

const NUMBERS = {
  infinitepay: [
    { phoneNumberId: "110000000000001", display: "551140000001" },
    { phoneNumberId: "110000000000002", display: "551140000002" },
  ],
  jim: [
    { phoneNumberId: "120000000000001", display: "15555550101" },
    { phoneNumberId: "120000000000002", display: "15555550102" },
  ],
};

export function whatsappBody(message, text) {
  const number = NUMBERS[message.brand][message.numberIndex];
  return JSON.stringify({
    object: "whatsapp_business_account",
    entry: [
      {
        id: number.phoneNumberId,
        changes: [
          {
            field: "messages",
            value: {
              messaging_product: "whatsapp",
              metadata: { display_phone_number: number.display, phone_number_id: number.phoneNumberId },
              contacts: [{ profile: { name: `Lojista ${message.from}` }, wa_id: message.from }],
              messages: [
                {
                  from: message.from,
                  id: message.externalId,
                  timestamp: String(Math.floor(Date.now() / 1000)),
                  type: "text",
                  text: { body: text },
                },
              ],
            },
          },
        ],
      },
    ],
  });
}

export function sendWhatsapp(message, text) {
  const body = whatsappBody(message, text);
  return http.post(`${CORE_URL}/channels/whatsapp/webhook`, body, {
    headers: {
      "Content-Type": "application/json",
      "X-Hub-Signature-256": `sha256=${hmac("sha256", WHATSAPP_APP_SECRET, body, "hex")}`,
    },
    timeout: TIMEOUT,
    tags: { channel: "whatsapp" },
  });
}

export function sendChat(message, text) {
  const body = JSON.stringify({
    brand: message.brand,
    app_user_id: message.appUserId,
    client_message_id: message.externalId,
    text: text,
    attachments: [],
  });
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = hmac("sha256", CHAT_SIGNING_SECRET, `${timestamp}.POST.${CHAT_PATH}.${body}`, "hex");
  return http.post(`${CORE_URL}${CHAT_PATH}`, body, {
    headers: {
      "Content-Type": "application/json",
      "X-Cloudesk-Timestamp": timestamp,
      "X-Cloudesk-Signature": signature,
    },
    responseType: "text",
    timeout: TIMEOUT,
    tags: { channel: "chat" },
  });
}

export function send(message, text) {
  return message.channel === "chat" ? sendChat(message, text) : sendWhatsapp(message, text);
}

// Registra no simulador o stream devolvido pelo Core, para que ele receba as respostas do chat.
export function registerStream(stream, appUserId) {
  return http.post(`${SIMULATOR_URL}/chat/streams`, JSON.stringify({ stream: stream, app_user_id: appUserId }), {
    headers: { "Content-Type": "application/json" },
    timeout: TIMEOUT,
    tags: { channel: "simulator" },
  });
}

// Uma linha de sent.jsonl.
export function record(run, message, sentAt, response) {
  console.log(
    JSON.stringify({
      stage: run,
      i: message.i,
      channel: message.channel,
      brand: message.brand,
      lane: message.lane,
      conv: message.conv,
      step: message.step,
      external_id: message.externalId,
      sent_at: sentAt.toISOString(),
      duration_ms: Math.round(response.timings.duration * 10) / 10,
      status: response.status,
      error: response.error || null,
    }),
  );
}
