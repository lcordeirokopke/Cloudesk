"""Apoio aos testes: personas de exemplo, configuração apontando para pastas temporárias e um
servidor SMTP falso em thread."""

import json
import socketserver
import threading
from dataclasses import replace

import pytest

from channel_simulator.config import Settings

PERSONAS = {
    "brands": [
        {
            "slug": "infinitepay",
            "locale": "pt-BR",
            "whatsapp_numbers": [
                {"phone_number_id": "110000000000001", "display": "551140000001"},
                {"phone_number_id": "110000000000002", "display": "551140000002"},
            ],
            "support_emails": ["financeiro@infinitepay.test", "suporte@infinitepay.test"],
            "contacts": [
                {"name": "Ana Lima", "whatsapp": "+5511912345678", "email": "ana.lima@example.com", "chat": "app-ana"},
                {"name": "Bruno Reis", "whatsapp": "+5521987654321", "email": "bruno.reis@example.com", "chat": "app-bruno"},
            ],
        },
        {
            "slug": "jim",
            "locale": "en-US",
            "whatsapp_numbers": [{"phone_number_id": "120000000000001", "display": "15555550101"}],
            "support_emails": ["support@jim.test"],
            "contacts": [
                {"name": "Alice Baker", "whatsapp": "+12125551234", "email": "alice.baker@example.com", "chat": "app-alice"}
            ],
        },
    ]
}


@pytest.fixture
def personas_path(tmp_path):
    path = tmp_path / "personas.json"
    path.write_text(json.dumps(PERSONAS), encoding="utf-8")
    return path


@pytest.fixture
def settings(tmp_path, personas_path):
    return replace(
        Settings(),
        whatsapp_app_secret="whatsapp-app-secret-de-teste",
        whatsapp_verify_token="whatsapp-verify-token-de-teste",
        whatsapp_access_token="whatsapp-access-token-de-teste",
        chat_signing_secret="chat-signing-secret-de-teste",
        personas_path=personas_path,
        data_dir=tmp_path / "data",
    )


class _SMTPHandler(socketserver.StreamRequestHandler):
    """SMTP mínimo: aceita EHLO, MAIL, RCPT, DATA e QUIT e guarda o conteúdo recebido."""

    def reply(self, line: str) -> None:
        self.wfile.write(f"{line}\r\n".encode())

    def handle(self):
        self.reply("220 smtp.test")
        envelope = {"rcpt": []}
        while True:
            line = self.rfile.readline().decode().rstrip("\r\n")
            if not line:
                return
            command = line.split(" ", 1)[0].upper()
            if command in ("EHLO", "HELO"):
                self.reply("250 smtp.test")
            elif command == "MAIL":
                envelope["from"] = line
                self.reply("250 OK")
            elif command == "RCPT":
                if self.server.refuse_recipients:
                    self.reply("550 recusado")
                else:
                    envelope["rcpt"].append(line)
                    self.reply("250 OK")
            elif command == "DATA":
                self.reply("354 fim com .")
                data = []
                while True:
                    chunk = self.rfile.readline()
                    if chunk in (b".\r\n", b".\n", b""):
                        break
                    data.append(chunk)
                self.server.messages.append({**envelope, "data": b"".join(data)})
                envelope = {"rcpt": []}
                self.reply("250 OK")
            elif command == "QUIT":
                self.reply("221 tchau")
                return
            else:
                self.reply("250 OK")


class FakeSMTPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _SMTPHandler)
        self.messages = []
        self.refuse_recipients = False


@pytest.fixture
def smtp_server():
    server = FakeSMTPServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server
    server.shutdown()
    server.server_close()
