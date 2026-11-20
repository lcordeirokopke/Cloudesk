"""Testes de contrato do agente.

Os schemas, os exemplos e os vetores de contracts/ são os mesmos que o RSpec do Core valida
(core/spec/contract/): todo exemplo de valid/ passa e todo exemplo de invalid/ falha.
"""

import json
import os
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from agent_mock import signature

REPOSITORY = Path(__file__).resolve().parents[3]
CONTRACTS = Path(os.environ.get("CONTRACTS_PATH", REPOSITORY / "contracts")) / "v1"

SCHEMAS = sorted(path.stem for path in (CONTRACTS / "schemas").glob("*.json"))


def read(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def validator(name: str) -> Draft202012Validator:
    return Draft202012Validator(read(CONTRACTS / "schemas" / f"{name}.json"))


def examples(kind: str) -> list[tuple[str, Path]]:
    return [
        (name, path)
        for name in SCHEMAS
        for path in sorted((CONTRACTS / "examples" / name / kind).glob("*.json"))
    ]


def example_id(value) -> str:
    return value.name if isinstance(value, Path) else str(value)


def test_encontra_os_schemas_do_contrato():
    assert SCHEMAS == [
        "action",
        "action-response",
        "context",
        "kafka.dlq-headers",
        "kafka.inbound-headers",
        "kafka.outbound-headers",
        "webhook.message-created",
    ]


@pytest.mark.parametrize("name", SCHEMAS)
def test_schema_e_json_schema_2020_12_valido(name):
    schema = read(CONTRACTS / "schemas" / f"{name}.json")

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    Draft202012Validator.check_schema(schema)


@pytest.mark.parametrize("name", SCHEMAS)
def test_schema_tem_exemplos_validos_e_invalidos(name):
    assert list((CONTRACTS / "examples" / name / "valid").glob("*.json"))
    assert list((CONTRACTS / "examples" / name / "invalid").glob("*.json"))


@pytest.mark.parametrize(("name", "path"), examples("valid"), ids=example_id)
def test_aceita_exemplo_valido(name, path):
    errors = [error.message for error in validator(name).iter_errors(read(path))]

    assert errors == []


@pytest.mark.parametrize(("name", "path"), examples("invalid"), ids=example_id)
def test_recusa_exemplo_invalido(name, path):
    assert not validator(name).is_valid(read(path))


SIGNATURE_VECTORS = read(CONTRACTS / "signature-vectors.json")


def test_janela_de_tempo_do_contrato():
    assert signature.TOLERANCE_SECONDS == SIGNATURE_VECTORS["tolerance_seconds"]


@pytest.mark.parametrize("vector", SIGNATURE_VECTORS["vectors"], ids=lambda vector: vector["description"])
def test_assina_o_vetor(vector):
    signed = signature.sign(
        vector["secret"], vector["timestamp"], vector["method"], vector["path"], vector["body"]
    )

    assert signed == vector["signature"]


def test_headers_de_uma_chamada_assinada():
    vector = SIGNATURE_VECTORS["vectors"][1]

    headers = signature.headers(
        vector["secret"], vector["method"].lower(), vector["path"], now=int(vector["timestamp"])
    )

    assert headers == {
        "X-Cloudesk-Timestamp": vector["timestamp"],
        "X-Cloudesk-Signature": vector["signature"],
    }
