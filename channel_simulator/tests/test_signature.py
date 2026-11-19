"""Assinatura do contrato, conferida com os vetores de contracts/v1/signature-vectors.json, os
mesmos do RSpec do Core e dos testes do agente mock."""

import json
import os
from pathlib import Path

import pytest

from channel_simulator import signature

REPOSITORY = Path(__file__).resolve().parents[2]
CONTRACTS = Path(os.environ.get("CONTRACTS_PATH", REPOSITORY / "contracts")) / "v1"
VECTORS = json.loads((CONTRACTS / "signature-vectors.json").read_text(encoding="utf-8"))


def test_janela_de_tempo_do_contrato():
    assert signature.TOLERANCE_SECONDS == VECTORS["tolerance_seconds"]


@pytest.mark.parametrize("vector", VECTORS["vectors"], ids=lambda vector: vector["description"])
def test_assina_o_vetor(vector):
    signed = signature.sign(vector["secret"], vector["timestamp"], vector["method"], vector["path"], vector["body"])

    assert signed == vector["signature"]


def test_headers_de_uma_chamada_assinada():
    vector = VECTORS["vectors"][0]

    headers = signature.headers(
        vector["secret"], vector["method"].lower(), vector["path"], vector["body"], now=int(vector["timestamp"])
    )

    assert headers == {
        "X-Cloudesk-Timestamp": vector["timestamp"],
        "X-Cloudesk-Signature": vector["signature"],
    }


def test_recusa_segredo_vazio():
    with pytest.raises(ValueError):
        signature.sign("", "1", "POST", "/", "")
