import email as stdlib_email
import random
from email import policy

import aiohttp
from aiohttp import web

from channel_simulator import email, templates
from channel_simulator.records import JsonlWriter, read_jsonl


def message(attachment=None):
    return email.build(
        from_name="Ana Lima",
        from_address="ana.lima@example.com",
        to_address="suporte@infinitepay.test",
        subject="Repasse não recebido",
        text="Meu repasse não caiu.",
        message_id="0199-id@simulator.cloudesk.test",
        attachment=attachment,
    )


# Montagem e envio


def test_id_da_mensagem_sem_sinais():
    message_id = email.new_message_id()

    assert message_id.endswith("@simulator.cloudesk.test")
    assert "<" not in message_id and ">" not in message_id


def test_monta_o_email_do_lojista():
    built = message()

    assert built["From"] == "Ana Lima <ana.lima@example.com>"
    assert built["To"] == "suporte@infinitepay.test"
    assert built["Subject"] == "Repasse não recebido"
    assert built["Message-ID"] == "<0199-id@simulator.cloudesk.test>"
    assert built.get_content_type() == "text/plain"
    assert built.get_content().strip() == "Meu repasse não caiu."


def test_monta_o_email_com_anexo():
    attachment = templates.attachment("document", random.Random(1))

    built = message(attachment)

    assert built.is_multipart()
    [part] = list(built.iter_attachments())
    assert part.get_filename() == "extrato.pdf"
    assert part.get_content_type() == "application/pdf"
    assert part.get_content() == attachment.data
    assert built.get_body(("plain",)).get_content().strip() == "Meu repasse não caiu."


async def test_envia_por_smtp_e_registra_250(smtp_server):
    host, port = smtp_server.server_address

    status, error = await email.send(host, port, message())

    assert (status, error) == (250, None)
    [received] = smtp_server.messages
    assert "ana.lima@example.com" in received["from"]
    assert "suporte@infinitepay.test" in received["rcpt"][0]
    parsed = stdlib_email.message_from_bytes(received["data"], policy=policy.default)
    assert parsed["Message-ID"] == "<0199-id@simulator.cloudesk.test>"


async def test_destinatario_recusado_registra_o_codigo_smtp(smtp_server):
    smtp_server.refuse_recipients = True
    host, port = smtp_server.server_address

    status, error = await email.send(host, port, message())

    assert status == 550
    assert "recusado" in error
    assert smtp_server.messages == []


async def test_smtp_fora_do_ar_registra_o_nome_do_erro(unused_tcp_port):
    status, error = await email.send("127.0.0.1", unused_tcp_port, message())

    assert status == "ConnectionRefusedError"
    assert error


# Poller do Mailpit


class FakeMailpit:
    """API do Mailpit com as mensagens informadas, em ordem decrescente de recebimento."""

    def __init__(self, messages: dict[str, dict]):
        self.messages = messages
        self.searches = []
        self.header_reads = []
        self.down = False
        self.app = web.Application()
        self.app.router.add_get("/api/v1/search", self.search)
        self.app.router.add_get("/api/v1/message/{id}/headers", self.headers)

    async def search(self, request):
        if self.down:
            return web.Response(status=503)
        self.searches.append(dict(request.query))
        start = int(request.query["start"])
        limit = int(request.query["limit"])
        ids = list(self.messages)
        page = [{"ID": mailpit_id, "Tags": ["cloudesk-ignored"]} for mailpit_id in ids[start : start + limit]]
        return web.json_response({"messages": page, "messages_count": len(ids), "total": len(ids), "start": start})

    async def headers(self, request):
        mailpit_id = request.match_info["id"]
        self.header_reads.append(mailpit_id)
        return web.json_response(self.messages[mailpit_id])


def headers_of(core_id: str | None):
    headers = {
        "From": ["suporte@infinitepay.test"],
        "To": ["ana.lima@example.com"],
        "Subject": ["Re: Repasse não recebido"],
    }
    if core_id:
        headers["X-Cloudesk-Message-Id"] = [core_id]
    return headers


async def poller_for(aiohttp_server, tmp_path, messages):
    fake = FakeMailpit(messages)
    server = await aiohttp_server(fake.app)
    received = JsonlWriter(tmp_path / "received.jsonl")
    poller = email.MailpitPoller(str(server.make_url("")), received, tmp_path / "mailpit_seen.jsonl")
    return fake, poller, received


async def test_grava_as_respostas_do_core_com_o_header_do_id(aiohttp_server, tmp_path):
    fake, poller, received = await poller_for(
        aiohttp_server, tmp_path, {"mp-2": headers_of("core-2"), "mp-1": headers_of(None)}
    )

    async with aiohttp.ClientSession() as session:
        recorded = await poller.poll_once(session)

    assert recorded == 1
    assert fake.searches[0] == {"query": "tag:cloudesk-ignored", "start": "0", "limit": "50"}
    [record] = read_jsonl(tmp_path / "received.jsonl")
    assert record == {
        "channel": "email",
        "core_message_id": "core-2",
        "recipient": "ana.lima@example.com",
        "sender": "suporte@infinitepay.test",
        "subject": "Re: Repasse não recebido",
        "received_at": record["received_at"],
        "mailpit_id": "mp-2",
    }
    assert poller.seen == {"mp-1", "mp-2"}
    received.close()
    poller.close()


async def test_decodifica_headers_codificados_na_rfc_2047(aiohttp_server, tmp_path):
    headers = {
        "From": ["=?UTF-8?Q?Suporte_Fran=C3=A7a?= <suporte@infinitepay.test>"],
        "To": ["ana.lima@example.com"],
        "Subject": ["=?UTF-8?Q?Re:_Repasse_n=C3=A3o_recebido?="],
        "X-Cloudesk-Message-Id": ["core-9"],
    }
    fake, poller, received = await poller_for(aiohttp_server, tmp_path, {"mp-9": headers})

    async with aiohttp.ClientSession() as session:
        await poller.poll_once(session)

    [record] = read_jsonl(tmp_path / "received.jsonl")
    assert record["subject"] == "Re: Repasse não recebido"
    assert record["sender"] == "Suporte França <suporte@infinitepay.test>"
    received.close()
    poller.close()


async def test_pagina_ate_o_fim(aiohttp_server, tmp_path):
    messages = {f"mp-{index:03}": headers_of(f"core-{index}") for index in range(120)}
    fake, poller, received = await poller_for(aiohttp_server, tmp_path, messages)

    async with aiohttp.ClientSession() as session:
        recorded = await poller.poll_once(session)

    assert recorded == 120
    assert [search["start"] for search in fake.searches] == ["0", "50", "100"]
    received.close()
    poller.close()


async def test_para_na_pagina_com_todos_os_ids_vistos(aiohttp_server, tmp_path):
    messages = {f"mp-{index:03}": headers_of(f"core-{index}") for index in range(120)}
    fake, poller, received = await poller_for(aiohttp_server, tmp_path, messages)
    async with aiohttp.ClientSession() as session:
        await poller.poll_once(session)
        fake.searches.clear()
        fake.header_reads.clear()

        recorded = await poller.poll_once(session)

    assert recorded == 0
    assert [search["start"] for search in fake.searches] == ["0"]
    assert fake.header_reads == []
    received.close()
    poller.close()


async def test_ids_vistos_sao_relidos_na_partida(aiohttp_server, tmp_path):
    fake, poller, received = await poller_for(aiohttp_server, tmp_path, {"mp-1": headers_of("core-1")})
    async with aiohttp.ClientSession() as session:
        await poller.poll_once(session)
    poller.close()

    restarted = email.MailpitPoller(
        str(poller.api_url), received, tmp_path / "mailpit_seen.jsonl"
    )
    async with aiohttp.ClientSession() as session:
        recorded = await restarted.poll_once(session)

    assert recorded == 0
    assert len(read_jsonl(tmp_path / "received.jsonl")) == 1
    received.close()
    restarted.close()


async def test_mailpit_fora_do_ar_tenta_no_ciclo_seguinte(aiohttp_server, tmp_path):
    fake, poller, received = await poller_for(aiohttp_server, tmp_path, {"mp-1": headers_of("core-1")})
    fake.down = True

    async with aiohttp.ClientSession() as session:
        try:
            await poller.poll_once(session)
            raised = False
        except aiohttp.ClientResponseError:
            raised = True
        fake.down = False
        recorded = await poller.poll_once(session)

    assert raised
    assert recorded == 1
    received.close()
    poller.close()
