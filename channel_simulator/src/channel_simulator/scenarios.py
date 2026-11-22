"""Cenários de demonstração roteirizados, com conferência no canal.

Cada cenário cria um lojista novo (personas.new_contact, com a semente e o run_id), envia os passos
pelo canal do cenário com textos fixos por locale e confere, em data/received.jsonl, as respostas
que chegam a esse lojista: o trecho esperado em cada resposta, na ordem, e a ausência de resposta
durante o silêncio do passo. No fim, imprime o comando bin/rails demo:check, que confere no Core as
expectativas do cenário (estado da conversa, handoff, eventos de auditoria).

| Cenário | Canal | Passos | No canal |
| - | - | - | - |
| reply | whatsapp | taxas | resposta com as taxas da marca |
| handoff | chat | mensagem sem intenção | nenhuma resposta em 10 s |
| reopen | chat | taxas; agradecimento; taxas | taxas; nada em 5 s; taxas sem prefixo da memória |
| memory, parte 1 | chat | taxas; agradecimento | taxas; nada em 5 s |
| memory, parte 2 | chat | taxas, com o lojista da parte 1 | taxas, começando com o prefixo da memória |
| failure-duplicate | chat | saudação com [falha:duplicate] | uma resposta e nada em 10 s |
| failure-stale | chat | saudação; saudação com [falha:stale] | boas-vindas; espera; nada em 50 s |
| failure-drop | chat | saudação com [falha:drop] | espera; nada em 50 s |
| failure-delay | chat | saudação com [falha:delay=50000] | espera; boas-vindas |

A parte 1 do memory imprime o memory:demo_close da conversa e o comando da parte 2
(--continue <run_id>), que lê o lojista em runs/<run_id>/scenario.json. Os cenários failure-stale,
failure-drop e failure-delay dependem da varredura do timeout com SLA de 1 min na regra genérica
(bin/rails panel:demo_sla BRAND=<slug> MINUTES=1); as saudações não têm categoria no Core e caem
nessa regra.

Cada execução grava runs/<run_id>/sent.jsonl e runs/<run_id>/scenario.json (cenário, parte, marca,
lojista, ids externos e conversation_id devolvidos pelo chat).
"""

import asyncio
import json
import random
import re
import time
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass

import aiohttp

from .config import Settings
from .personas import Contact, Personas, new_contact
from .records import JsonlWriter
from .sender import new_run_id, planned_text, send_one
from .server import RECEIVED_FILE

TEXTS = {
    "pt-BR": {
        "taxas": "Qual a taxa do crédito parcelado em 12x?",
        "agradecimento": "Obrigado, era só isso!",
        "sem_intencao": "Quero mudar o endereço cadastrado.",
        "saudacao": "Oi, tudo bem? Preciso de ajuda.",
    },
    "en-US": {
        "taxas": "What is the fee for credit card installments?",
        "agradecimento": "Thank you, that is all!",
        "sem_intencao": "I want to change my address.",
        "saudacao": "Hi, how are you? I need help.",
    },
}

# Trechos esperados nas respostas: textos do agente mock e mensagem de espera do Core.
EXPECTED = {
    "pt-BR": {
        "taxas": "As taxas da sua conta são:",
        "saudacao": "Me conte o assunto do atendimento",
        "espera": "Estamos verificando sua solicitação",
        "memoria": "Vi que você já falou com a gente sobre taxas em ",
    },
    "en-US": {
        "taxas": "Your account fees are:",
        "saudacao": "Tell me what you need help with",
        "espera": "We are checking your request",
        "memoria": "I see you contacted us about fees on ",
    },
}

REPLY_TIMEOUT = 30.0
SWEEP_TIMEOUT = 100.0


@dataclass(frozen=True)
class Reply:
    """Resposta esperada: contém o trecho key e, com starts_with, começa com esse trecho."""

    key: str
    timeout: float = REPLY_TIMEOUT
    starts_with: str | None = None


@dataclass(frozen=True)
class Step:
    """Passo: texto (chave de TEXTS) com o marcador de falha, respostas na ordem e silêncio depois."""

    text: str
    marker: str = ""
    replies: tuple[Reply, ...] = ()
    quiet: float = 0.0


@dataclass(frozen=True)
class Scenario:
    name: str
    channel: str
    steps: tuple[Step, ...]
    continuation: tuple[Step, ...] = ()
    needs_demo_sla: bool = False


SCENARIOS = {
    scenario.name: scenario
    for scenario in (
        Scenario("reply", "whatsapp", (Step("taxas", replies=(Reply("taxas"),)),)),
        Scenario("handoff", "chat", (Step("sem_intencao", quiet=10),)),
        Scenario("reopen", "chat", (
            Step("taxas", replies=(Reply("taxas"),)),
            Step("agradecimento", quiet=5),
            Step("taxas", replies=(Reply("taxas", starts_with="taxas"),)),
        )),
        Scenario(
            "memory", "chat",
            (Step("taxas", replies=(Reply("taxas"),)), Step("agradecimento", quiet=5)),
            continuation=(Step("taxas", replies=(Reply("taxas", starts_with="memoria"),)),),
        ),
        Scenario("failure-duplicate", "chat", (
            Step("saudacao", marker="[falha:duplicate]", replies=(Reply("saudacao"),), quiet=10),
        )),
        Scenario("failure-stale", "chat", (
            Step("saudacao", replies=(Reply("saudacao"),)),
            Step("saudacao", marker="[falha:stale]", replies=(Reply("espera", SWEEP_TIMEOUT),), quiet=50),
        ), needs_demo_sla=True),
        Scenario("failure-drop", "chat", (
            Step("saudacao", marker="[falha:drop]", replies=(Reply("espera", SWEEP_TIMEOUT),), quiet=50),
        ), needs_demo_sla=True),
        Scenario("failure-delay", "chat", (
            Step("saudacao", marker="[falha:delay=50000]",
                 replies=(Reply("espera", SWEEP_TIMEOUT), Reply("saudacao", 60))),
        ), needs_demo_sla=True),
    )
}

NAMES = tuple(SCENARIOS)

Send = Callable[[aiohttp.ClientSession, Settings, str, object], Awaitable[dict]]


def step_text(locale: str, step: Step) -> str:
    text = TEXTS[locale][step.text]
    return f"{text} {step.marker}" if step.marker else text


def _digits(value) -> str:
    return re.sub(r"\D", "", str(value or ""))


class Inbox:
    """Respostas novas de received.jsonl para o lojista no canal, desde a criação."""

    def __init__(self, path, channel: str, contact: Contact):
        self.path = path
        self.channel = channel
        self.contact = contact
        self.pending: list[dict] = []
        self._offset = self.path.stat().st_size if self.path.exists() else 0

    def _matches(self, record: dict) -> bool:
        if record.get("channel") != self.channel:
            return False
        if self.channel == "whatsapp":
            return _digits(record.get("recipient")) == _digits(self.contact.whatsapp)
        return record.get("recipient") == self.contact.identity(self.channel)

    def refresh(self) -> None:
        """Lê as linhas completas novas; uma linha ainda sem quebra fica para a próxima leitura."""
        if not self.path.exists():
            return
        with self.path.open("rb") as file:
            file.seek(self._offset)
            data = file.read()
        complete = data[: data.rfind(b"\n") + 1]
        self._offset += len(complete)
        for line in complete.decode("utf-8").splitlines():
            if line.strip():
                record = json.loads(line)
                if self._matches(record):
                    self.pending.append(record)


@dataclass
class Check:
    label: str
    ok: bool
    detail: str


class Runner:
    def __init__(self, settings: Settings, send: Send, sleep, monotonic, poll_seconds: float, out):
        self.settings = settings
        self.send = send
        self.sleep = sleep
        self.monotonic = monotonic
        self.poll_seconds = poll_seconds
        self.out = out
        self.checks: list[Check] = []

    def check(self, label: str, ok: bool, detail: str) -> bool:
        self.checks.append(Check(label, ok, detail))
        self.out(f"{'ok' if ok else 'falhou':7} {label}: {detail}")
        return ok

    async def wait_reply(self, inbox: Inbox, locale: str, reply: Reply, label: str) -> bool:
        deadline = self.monotonic() + reply.timeout
        expected = EXPECTED[locale][reply.key]
        prefix = EXPECTED[locale][reply.starts_with] if reply.starts_with else None
        while True:
            inbox.refresh()
            if inbox.pending:
                text = str(inbox.pending.pop(0).get("text") or "")
                ok = expected in text and (prefix is None or text.startswith(prefix))
                wanted = f"{expected!r}" + (f", começando com {prefix!r}" if prefix else "")
                return self.check(label, ok, f"esperado {wanted}; recebido {text!r}")
            if self.monotonic() >= deadline:
                return self.check(label, False, f"nenhuma resposta em {reply.timeout:g} s; esperado {expected!r}")
            await self.sleep(self.poll_seconds)

    async def wait_quiet(self, inbox: Inbox, seconds: float, label: str) -> bool:
        deadline = self.monotonic() + seconds
        while True:
            inbox.refresh()
            if inbox.pending:
                text = str(inbox.pending.pop(0).get("text") or "")
                return self.check(label, False, f"resposta inesperada {text!r}")
            if self.monotonic() >= deadline:
                return self.check(label, True, f"nenhuma resposta em {seconds:g} s")
            await self.sleep(self.poll_seconds)


def _load_previous(settings: Settings, run_id: str, name: str, brand_slug: str) -> dict:
    path = settings.data_dir / "runs" / run_id / "scenario.json"
    if not path.exists():
        raise ValueError(f"{path} não existe")
    previous = json.loads(path.read_text(encoding="utf-8"))
    if previous.get("scenario") != name or previous.get("part") != 1:
        raise ValueError(f"a execução {run_id} não é a parte 1 do cenário {name}")
    if previous.get("brand") != brand_slug:
        raise ValueError(f"a execução {run_id} é da marca {previous.get('brand')}")
    return previous


async def run_scenario(settings: Settings, personas: Personas, name: str, brand_slug: str, seed: int = 1,
                       continue_run: str | None = None, *, send: Send = send_one, sleep=asyncio.sleep,
                       monotonic=time.monotonic, poll_seconds: float = 0.5, out=print) -> int:
    """Executa o cenário e devolve o código de saída: 0 com todas as expectativas no canal cumpridas."""
    scenario = SCENARIOS[name]
    if continue_run and not scenario.continuation:
        raise ValueError(f"o cenário {name} não tem parte 2 (--continue)")

    brand = personas.brand(brand_slug)
    locale = brand.locale
    run_id = new_run_id()
    rng = random.Random(f"{seed}:{run_id}")
    previous = _load_previous(settings, continue_run, name, brand_slug) if continue_run else None
    if previous:
        contact = Contact(**previous["contact"])
        steps, part = scenario.continuation, 2
    else:
        contact = new_contact(brand, rng)
        steps, part = scenario.steps, 1

    title = f"cenário {name}" + (f", parte {part}" if scenario.continuation else "")
    out(f"{title}, marca {brand.slug}, lojista {contact.name} ({contact.identity(scenario.channel)}), run_id {run_id}")
    if scenario.needs_demo_sla:
        out(f"pré-requisito: docker compose exec web bin/rails panel:demo_sla BRAND={brand.slug} MINUTES=1")

    runner = Runner(settings, send, sleep, monotonic, poll_seconds, out)
    inbox = Inbox(settings.data_dir / RECEIVED_FILE, scenario.channel, contact)
    run_dir = settings.data_dir / "runs" / run_id
    external_ids: list[str] = []
    conversation_ids: list[str] = []

    with JsonlWriter(run_dir / "sent.jsonl") as writer:
        async with aiohttp.ClientSession() as session:
            for number, step in enumerate(steps, 1):
                text = step_text(locale, step)
                record = await send(session, settings, run_id,
                                    planned_text(brand, scenario.channel, contact, text, step.text, rng))
                writer.write(record)
                if record.get("external_id"):
                    external_ids.append(record["external_id"])
                if record.get("conversation_id") and record["conversation_id"] not in conversation_ids:
                    conversation_ids.append(record["conversation_id"])
                status = record.get("status")
                if not runner.check(f"passo {number} enviado", isinstance(status, int) and 200 <= status < 300,
                                    f"{text!r}, status {status}"):
                    break
                passed = True
                for index, reply in enumerate(step.replies, 1):
                    passed = await runner.wait_reply(inbox, locale, reply, f"passo {number}, resposta {index}")
                    if not passed:
                        break
                if passed and step.quiet:
                    passed = await runner.wait_quiet(inbox, step.quiet, f"passo {number}, silêncio")
                if not passed:
                    break

    failed = [check for check in runner.checks if not check.ok]
    if failed and scenario.needs_demo_sla and any("nenhuma resposta" in check.detail for check in failed):
        out(f"a varredura do timeout não respondeu; confira o SLA de 1 min da regra genérica: "
            f"docker compose exec web bin/rails panel:demo_sla BRAND={brand.slug} MINUTES=1")

    all_external_ids = (previous["external_ids"] if previous else []) + external_ids
    (run_dir / "scenario.json").write_text(json.dumps({
        "run_id": run_id, "scenario": name, "part": part, "brand": brand.slug, "channel": scenario.channel,
        "contact": asdict(contact), "external_ids": external_ids, "conversation_ids": conversation_ids,
        "continues": continue_run,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    if scenario.continuation and part == 1:
        conversation = conversation_ids[0] if conversation_ids else "<conversation_id>"
        out(f"encerramento da parte 1: docker compose exec web bin/rails memory:demo_close CONVERSATION={conversation}")
        out(f"parte 2: docker compose exec channel-simulator channel-simulator scenario {name} "
            f"--brand {brand.slug} --continue {run_id}")
    else:
        out(f"conferência no Core: docker compose exec web bin/rails demo:check SCENARIO={name} "
            f"BRAND={brand.slug} CHANNEL={scenario.channel} EXTERNAL_IDS={','.join(all_external_ids)}")

    out(f"resultado no canal: {'falhou' if failed else 'ok'}")
    return 1 if failed else 0
