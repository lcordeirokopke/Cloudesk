import hashlib
import uuid

import pytest

from agent_mock import failure

EVENT_ID = "019a8f3e-5b7a-7c21-9d43-1f2e3a4b5c6d"


def test_fracao_vem_dos_primeiros_8_hex_do_sha256():
    expected = int(hashlib.sha256(EVENT_ID.encode()).hexdigest()[:8], 16) / 2**32

    assert failure.fraction(EVENT_ID) == expected
    assert 0 <= failure.fraction(EVENT_ID) < 1


def test_escolha_deterministica():
    assert failure.affected(EVENT_ID, 0.5) == failure.affected(EVENT_ID, 0.5)


def test_taxa_1_afeta_todos_e_taxa_0_nenhum():
    ids = [str(uuid.UUID(int=index)) for index in range(200)]

    assert all(failure.affected(event_id, 1) for event_id in ids)
    assert not any(failure.affected(event_id, 0) for event_id in ids)


def test_proporcao_numa_amostra_fixa():
    ids = [str(uuid.UUID(int=index * 7919)) for index in range(10_000)]

    share = sum(failure.affected(event_id, 0.3) for event_id in ids) / len(ids)

    assert 0.28 < share < 0.32


@pytest.mark.parametrize("mode", ["drop", "duplicate", "stale", "delay"])
def test_marcador_de_cada_modo(mode):
    found, text = failure.marker(f"Oi [falha:{mode}] tudo bem?")

    assert found == failure.Marker(mode)
    assert text == "Oi tudo bem?"


def test_delay_com_e_sem_valor():
    assert failure.marker("[falha:delay=50000] Oi") == (failure.Marker("delay", 50000), "Oi")
    assert failure.marker("Oi [falha:delay]") == (failure.Marker("delay", None), "Oi")


@pytest.mark.parametrize("text", ["Oi [falha:drop=10]", "Oi [FALHA:drop]", "Oi [falha:Drop]", "Oi [falha:explode]",
                                  "Oi [falha: drop]", "Oi [nota] aqui"])
def test_texto_entre_colchetes_fora_do_formato_nao_e_marcador(text):
    assert failure.marker(text) == (None, text)


def test_colchetes_de_outro_formato_ficam_no_texto():
    assert failure.marker("Oi [falha:drop=10] [falha:stale] [nota]") == (
        failure.Marker("stale"), "Oi [falha:drop=10] [nota]")


def test_dois_marcadores_vale_o_primeiro_e_os_dois_saem():
    assert failure.marker("[falha:duplicate] Oi [falha:delay=10]") == (failure.Marker("duplicate"), "Oi")


def test_espacos_reduzidos_e_pontas_aparadas():
    assert failure.marker("  Oi   [falha:drop]   tudo\tbem?  ") == (failure.Marker("drop"), "Oi tudo bem?")


def test_texto_sem_marcador_sem_mudanca():
    text = "  Oi,   tudo bem?  "

    assert failure.marker(text) == (None, text)
