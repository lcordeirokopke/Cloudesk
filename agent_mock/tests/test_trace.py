import pytest

from agent_mock import trace

HEADER = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"


def test_continua_o_trace_com_parent_id_novo():
    child = trace.continue_trace(HEADER)

    assert child.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert child.parent_id != "00f067aa0ba902b7"
    assert child.flags == "01"
    assert trace.PATTERN.match(str(child))


def test_aceita_header_em_bytes():
    assert trace.continue_trace(HEADER.encode()).trace_id == "4bf92f3577b34da6a3ce929d0e0e4736"


@pytest.mark.parametrize("header", [
    None,
    "",
    "lixo",
    "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
    "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
    "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
])
def test_header_invalido_inicia_trace(header):
    assert trace.parse(header) is None

    started = trace.continue_trace(header)

    assert trace.PATTERN.match(str(started))
    assert started.trace_id != "4bf92f3577b34da6a3ce929d0e0e4736"
    assert started.flags == trace.SAMPLED
