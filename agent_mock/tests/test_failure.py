import hashlib
import uuid

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
