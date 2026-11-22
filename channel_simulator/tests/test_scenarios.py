"""Executor dos cenários de demonstração, com o envio e o received.jsonl simulados."""

import json
import uuid

import pytest

from channel_simulator import cli, personas, scenarios
from channel_simulator.records import JsonlWriter
from channel_simulator.server import RECEIVED_FILE


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    async def sleep(self, seconds):
        self.now += seconds


class FakeChannel:
    """Envio falso: devolve o registro do sent.jsonl e grava as respostas programadas em received.jsonl.

    replies é uma lista por passo enviado, com os textos que o lojista recebe logo depois do envio.
    """

    def __init__(self, settings, replies, conversation_id=None, status=200):
        self.settings = settings
        self.replies = list(replies)
        self.conversation_id = conversation_id or str(uuid.uuid4())
        self.status = status
        self.sent = []

    async def __call__(self, session, settings, run_id, item):
        record = {"run_id": run_id, "channel": item.channel, "brand": item.brand.slug,
                  "identity": item.contact.identity(item.channel), "external_id": str(uuid.uuid4()),
                  "intent": item.content.intent, "text": item.content.text, "status": self.status}
        if item.channel == "chat":
            record["conversation_id"] = self.conversation_id
        self.sent.append((item, record))
        recipient = item.contact.chat if item.channel == "chat" else item.contact.whatsapp.lstrip("+")
        texts = self.replies.pop(0) if self.replies else []
        with JsonlWriter(settings.data_dir / RECEIVED_FILE) as writer:
            writer.write({"channel": item.channel, "recipient": "outro-lojista", "text": "resposta de outra conversa"})
            for text in texts:
                writer.write({"channel": item.channel, "recipient": recipient, "text": text})
        return record


@pytest.fixture
def loaded(personas_path):
    return personas.load(personas_path)


async def run(settings, loaded, name, replies, brand="infinitepay", continue_run=None, **channel_options):
    channel = FakeChannel(settings, replies, **channel_options)
    clock = Clock()
    lines = []
    code = await scenarios.run_scenario(settings, loaded, name, brand, 1, continue_run, send=channel,
                                        sleep=clock.sleep, monotonic=clock.monotonic, poll_seconds=0.5,
                                        out=lines.append)
    return code, lines, channel


def expected(locale, key):
    return scenarios.EXPECTED[locale][key]


def scenario_file(settings, lines):
    run_id = lines[0].rsplit("run_id ", 1)[1]
    return json.loads((settings.data_dir / "runs" / run_id / "scenario.json").read_text(encoding="utf-8")), run_id


def test_cada_cenario_tem_textos_e_respostas_nos_dois_locales():
    for scenario in scenarios.SCENARIOS.values():
        for step in scenario.steps + scenario.continuation:
            for locale in ("pt-BR", "en-US"):
                assert scenarios.TEXTS[locale][step.text]
                for reply in step.replies:
                    assert scenarios.EXPECTED[locale][reply.key]
                    assert reply.starts_with is None or scenarios.EXPECTED[locale][reply.starts_with]


@pytest.mark.parametrize("name, markers", [
    ("failure-duplicate", ["[falha:duplicate]"]),
    ("failure-stale", ["", "[falha:stale]"]),
    ("failure-drop", ["[falha:drop]"]),
    ("failure-delay", ["[falha:delay=50000]"]),
])
def test_cenarios_de_falha_levam_o_marcador_certo(name, markers):
    scenario = scenarios.SCENARIOS[name]

    assert [step.marker for step in scenario.steps] == markers
    assert scenario.needs_demo_sla == (name != "failure-duplicate")
    for step in scenario.steps:
        text = scenarios.step_text("pt-BR", step)
        assert text.endswith(step.marker)


def test_cenarios_sem_falha_nao_levam_marcador():
    for name in ("reply", "handoff", "reopen", "memory"):
        scenario = scenarios.SCENARIOS[name]
        assert all(step.marker == "" for step in scenario.steps + scenario.continuation)


async def test_expectativa_cumprida(settings, loaded):
    code, lines, channel = await run(settings, loaded, "reply", [[expected("pt-BR", "taxas") + " débito 1,37%."]])

    assert code == 0
    assert any(line.startswith("ok      passo 1, resposta 1") for line in lines)
    assert lines[-1] == "resultado no canal: ok"
    item, record = channel.sent[0]
    assert item.channel == "whatsapp"
    assert item.contact.origin == "new"
    assert item.content.text == scenarios.TEXTS["pt-BR"]["taxas"]


async def test_resposta_faltando(settings, loaded):
    code, lines, _channel = await run(settings, loaded, "reply", [[]])

    assert code == 1
    assert any(line.startswith("falhou  passo 1, resposta 1: nenhuma resposta em 30 s") for line in lines)
    assert lines[-1] == "resultado no canal: falhou"


async def test_resposta_diferente_da_esperada(settings, loaded):
    code, lines, _channel = await run(settings, loaded, "reply", [["Outra coisa"]])

    assert code == 1
    assert any("recebido 'Outra coisa'" in line for line in lines)


async def test_resposta_a_mais_no_silencio(settings, loaded):
    greeting = expected("pt-BR", "saudacao")

    code, lines, channel = await run(settings, loaded, "failure-duplicate", [[greeting, greeting]])

    assert code == 1
    assert any(line.startswith("falhou  passo 1, silêncio: resposta inesperada") for line in lines)
    assert channel.sent[0][0].content.text.endswith("[falha:duplicate]")


async def test_silencio_cumprido_no_handoff(settings, loaded):
    code, lines, _channel = await run(settings, loaded, "handoff", [[]])

    assert code == 0
    assert any(line.startswith("ok      passo 1, silêncio: nenhuma resposta em 10 s") for line in lines)


async def test_status_de_envio_com_erro_para_o_cenario(settings, loaded):
    code, lines, channel = await run(settings, loaded, "reopen", [], status=500)

    assert code == 1
    assert len(channel.sent) == 1
    assert any(line.startswith("falhou  passo 1 enviado") for line in lines)


async def test_reopen_confere_a_resposta_sem_prefixo(settings, loaded):
    fees = expected("pt-BR", "taxas")
    prefixed = expected("pt-BR", "memoria") + "01/11/2026. " + fees

    code, lines, _channel = await run(settings, loaded, "reopen", [[fees], [], [prefixed]])

    assert code == 1
    assert any("passo 3, resposta 1" in line and line.startswith("falhou") for line in lines)


async def test_cenario_de_timeout_lembra_o_sla(settings, loaded):
    code, lines, _channel = await run(settings, loaded, "failure-drop", [[]])

    assert code == 1
    assert lines[1] == "pré-requisito: docker compose exec web bin/rails panel:demo_sla BRAND=infinitepay MINUTES=1"
    assert any(line.startswith("a varredura do timeout não respondeu") for line in lines)


async def test_failure_delay_espera_a_espera_e_a_resposta(settings, loaded):
    code, _lines, channel = await run(
        settings, loaded, "failure-delay", [[expected("pt-BR", "espera"), expected("pt-BR", "saudacao")]])

    assert code == 0
    assert channel.sent[0][0].content.text == "Oi, tudo bem? Preciso de ajuda. [falha:delay=50000]"


async def test_textos_em_en_us_para_jim(settings, loaded):
    code, _lines, channel = await run(settings, loaded, "reply", [[expected("en-US", "taxas")]], brand="jim")

    assert code == 0
    assert channel.sent[0][0].content.text == scenarios.TEXTS["en-US"]["taxas"]


async def test_scenario_json_e_comando_demo_check(settings, loaded):
    code, lines, channel = await run(settings, loaded, "handoff", [[]])

    data, run_id = scenario_file(settings, lines)
    external_ids = [record["external_id"] for _item, record in channel.sent]
    assert code == 0
    assert data["scenario"] == "handoff" and data["part"] == 1 and data["brand"] == "infinitepay"
    assert data["external_ids"] == external_ids
    assert data["conversation_ids"] == [channel.conversation_id]
    assert data["contact"]["chat"] == channel.sent[0][0].contact.chat
    sent = (settings.data_dir / "runs" / run_id / "sent.jsonl").read_text(encoding="utf-8").splitlines()
    assert len(sent) == 1
    assert (f"conferência no Core: docker compose exec web bin/rails demo:check SCENARIO=handoff BRAND=infinitepay "
            f"CHANNEL=chat EXTERNAL_IDS={external_ids[0]}") in lines


async def test_lojista_novo_a_cada_execucao(settings, loaded):
    _code, _lines, first = await run(settings, loaded, "handoff", [[]])
    _code, _lines, second = await run(settings, loaded, "handoff", [[]])

    assert first.sent[0][0].contact.chat != second.sent[0][0].contact.chat


async def test_memory_em_duas_partes(settings, loaded):
    fees = expected("pt-BR", "taxas")
    code, lines, first = await run(settings, loaded, "memory", [[fees], []])
    part1, run_id = scenario_file(settings, lines)

    assert code == 0
    assert (f"encerramento da parte 1: docker compose exec web bin/rails memory:demo_close "
            f"CONVERSATION={first.conversation_id}") in lines
    assert (f"parte 2: docker compose exec channel-simulator channel-simulator scenario memory --brand infinitepay "
            f"--continue {run_id}") in lines
    assert not any("demo:check" in line for line in lines)

    prefixed = expected("pt-BR", "memoria") + "21/11/2026. " + fees
    code, lines, second = await run(settings, loaded, "memory", [[prefixed]], continue_run=run_id)
    part2, _run_id = scenario_file(settings, lines)

    assert code == 0
    assert second.sent[0][0].contact == first.sent[0][0].contact
    assert part2["part"] == 2 and part2["continues"] == run_id
    all_ids = part1["external_ids"] + part2["external_ids"]
    assert len(all_ids) == 3
    assert any(line.endswith(f"SCENARIO=memory BRAND=infinitepay CHANNEL=chat EXTERNAL_IDS={','.join(all_ids)}")
               for line in lines)


async def test_memory_parte_2_sem_prefixo_falha(settings, loaded):
    fees = expected("pt-BR", "taxas")
    _code, lines, _first = await run(settings, loaded, "memory", [[fees], []])
    _part1, run_id = scenario_file(settings, lines)

    code, _lines, _second = await run(settings, loaded, "memory", [[fees]], continue_run=run_id)

    assert code == 1


async def test_continue_recusa_execucao_que_nao_e_parte_1(settings, loaded):
    _code, lines, _channel = await run(settings, loaded, "handoff", [[]])
    _data, run_id = scenario_file(settings, lines)

    with pytest.raises(ValueError, match="não é a parte 1"):
        await run(settings, loaded, "memory", [], continue_run=run_id)
    with pytest.raises(ValueError, match="não tem parte 2"):
        await run(settings, loaded, "reply", [], continue_run=run_id)


def test_cli_recusa_continue_fora_do_memory(settings, monkeypatch):
    monkeypatch.setenv("PERSONAS_PATH", str(settings.personas_path))
    monkeypatch.setenv("SIMULATOR_DATA_DIR", str(settings.data_dir))

    with pytest.raises(SystemExit) as error:
        cli.main(["scenario", "reply", "--continue", "abc"])

    assert error.value.code == 2


def test_cli_aceita_os_cenarios():
    for name in ("cross-channel", *scenarios.NAMES):
        assert cli.build_parser().parse_args(["scenario", name]).name == name
    assert cli.build_parser().parse_args(["scenario", "memory", "--continue", "r1"]).continue_run == "r1"
