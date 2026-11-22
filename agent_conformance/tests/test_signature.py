import pytest

from agent_conformance import signature


def test_assinatura_dos_vetores(vectors):
    for vector in vectors("signature-vectors")["vectors"]:
        assert signature.sign(vector["secret"], vector["timestamp"], vector["method"], vector["path"],
                              vector["body"]) == vector["signature"], vector["description"]


def test_conferencia_aceita_os_vetores_dentro_da_janela(vectors):
    for vector in vectors("signature-vectors")["vectors"]:
        headers = {signature.TIMESTAMP_HEADER: vector["timestamp"], signature.SIGNATURE_HEADER: vector["signature"]}

        assert signature.problem(vector["secret"], headers, vector["method"], vector["path"], vector["body"],
                                 now=int(vector["timestamp"]) + 300) is None


@pytest.mark.parametrize("change, expected", [
    ({"now_offset": 301}, "fora da janela"),
    ({"signature": "0" * 64}, "não confere"),
    ({"secret": "outro"}, "não confere"),
    ({"drop": signature.SIGNATURE_HEADER}, "ausentes"),
    ({"timestamp": "abc"}, "inválido"),
])
def test_conferencia_recusa(vectors, change, expected):
    vector = vectors("signature-vectors")["vectors"][1]
    headers = {signature.TIMESTAMP_HEADER: change.get("timestamp", vector["timestamp"]),
               signature.SIGNATURE_HEADER: change.get("signature", vector["signature"])}
    headers.pop(change.get("drop"), None)
    now = int(vector["timestamp"]) + change.get("now_offset", 0)

    problem = signature.problem(change.get("secret", vector["secret"]), headers, vector["method"], vector["path"],
                                vector["body"], now=now)

    assert expected in problem


def test_regra_da_idempotency_key_pelos_vetores(vectors):
    from test_conformance import idempotency_key

    for vector in vectors("idempotency-key-vectors")["vectors"]:
        assert idempotency_key({"inbound_event_id": vector["inbound_event_id"], "type": vector["type"]}) == (
            vector["idempotency_key"])
