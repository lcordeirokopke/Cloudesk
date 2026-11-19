from channel_simulator.records import JsonlWriter, read_jsonl, utc_now


def test_grava_uma_linha_json_por_registro(tmp_path):
    path = tmp_path / "sub" / "sent.jsonl"

    with JsonlWriter(path) as writer:
        writer.write({"id": 1, "text": "repasse não caiu"})
        writer.write({"id": 2})

    lines = path.read_text(encoding="utf-8").splitlines()
    assert lines == ['{"id":1,"text":"repasse não caiu"}', '{"id":2}']


def test_acrescenta_ao_arquivo_existente(tmp_path):
    path = tmp_path / "received.jsonl"
    with JsonlWriter(path) as writer:
        writer.write({"id": 1})

    with JsonlWriter(path) as writer:
        writer.write({"id": 2})

    assert read_jsonl(path) == [{"id": 1}, {"id": 2}]


def test_cada_linha_fica_no_disco_logo_depois_do_write(tmp_path):
    path = tmp_path / "received.jsonl"
    writer = JsonlWriter(path)

    writer.write({"id": 1})

    assert read_jsonl(path) == [{"id": 1}]
    writer.close()


def test_le_arquivo_inexistente_como_lista_vazia(tmp_path):
    assert read_jsonl(tmp_path / "nada.jsonl") == []


def test_horario_utc_com_milissegundos():
    value = utc_now()

    assert value.endswith("Z")
    assert len(value) == len("2026-11-19T12:00:00.000Z")
