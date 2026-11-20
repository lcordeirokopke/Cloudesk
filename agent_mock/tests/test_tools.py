from collections import Counter

import pytest

from agent_mock import tools

SAMPLE = 2000


def test_mesma_entrada_mesmo_retorno():
    for name, tool_input in [
        ("consultar_transacao", {"id_transacao": "TX4815162342"}),
        ("consultar_repasse", {"data": "2026-11-12"}),
        ("consultar_repasse", {}),
        ("consultar_taxas", {"marca": "infinitepay"}),
        ("status_maquininha", {"numero_serie": "SN12345678"}),
    ]:
        assert tools.TOOLS[name](tool_input) == tools.TOOLS[name](dict(tool_input))


def test_entrada_canonica_ignora_ordem_das_chaves():
    assert tools.digest("x", {"a": 1, "b": 2}) == tools.digest("x", {"b": 2, "a": 1})


def proportions(name, inputs):
    counts = Counter(tools.TOOLS[name](tool_input)["status"] for tool_input in inputs)
    return {status: count / len(inputs) for status, count in counts.items()}


def assert_close(found, expected):
    assert set(found) == set(expected)
    for status, share in expected.items():
        assert found[status] == pytest.approx(share, abs=0.04), status


def test_proporcoes_da_transacao():
    inputs = [{"id_transacao": f"TX{1_000_000_000 + index}"} for index in range(SAMPLE)]

    assert_close(proportions("consultar_transacao", inputs),
                 {"aprovada": 0.60, "estornada": 0.15, "contestada": 0.15, "nao_encontrada": 0.10})


def test_proporcoes_do_repasse():
    inputs = [{"data": f"{2020 + index // 365:04d}-01-01", "n": index} for index in range(SAMPLE)]

    assert_close(proportions("consultar_repasse", inputs), {"pago": 0.50, "agendado": 0.30, "nao_encontrado": 0.20})


def test_proporcoes_da_maquininha():
    inputs = [{"numero_serie": f"SN{10_000_000 + index}"} for index in range(SAMPLE)]

    assert_close(proportions("status_maquininha", inputs), {"online": 0.50, "offline": 0.30, "defeito": 0.20})


def test_formato_do_retorno():
    approved = next(
        output for index in range(100)
        if (output := tools.consultar_transacao({"id_transacao": f"TX{1_000_000_000 + index}"}))["status"] == "aprovada"
    )

    assert set(approved) == {"status", "valor", "data"}
    assert approved["valor"].count(".") == 1 and len(approved["valor"].split(".")[1]) == 2


def test_taxas_fixas_por_marca():
    assert tools.consultar_taxas({"marca": "infinitepay"}) == tools.FEES["infinitepay"]
    assert tools.consultar_taxas({"marca": "jim"}) == tools.FEES["jim"]
    assert tools.consultar_taxas({"marca": "outra"}) == tools.DEFAULT_FEES


def test_registro_da_chamada():
    times = iter(["2026-11-13T14:02:11.720Z", "2026-11-13T14:02:11.760Z"])

    record = tools.call("status_maquininha", {"numero_serie": "SN12345678"}, lambda: next(times))

    assert record == {
        "name": "status_maquininha",
        "input": {"numero_serie": "SN12345678"},
        "output": tools.status_maquininha({"numero_serie": "SN12345678"}),
        "started_at": "2026-11-13T14:02:11.720Z",
        "finished_at": "2026-11-13T14:02:11.760Z",
    }
