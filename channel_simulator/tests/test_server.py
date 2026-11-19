from channel_simulator.records import read_jsonl
from channel_simulator.server import create_app


async def test_health(aiohttp_client, settings):
    client = await aiohttp_client(create_app(settings, background=False))

    response = await client.get("/health")

    assert response.status == 200
    assert await response.json() == {"status": "ok"}


async def test_rotas_dos_receptores(aiohttp_client, settings):
    client = await aiohttp_client(create_app(settings, background=False))

    whatsapp = await client.post(
        "/v21.0/110000000000001/messages",
        json={"messaging_product": "whatsapp", "to": "5511912345678", "type": "text", "text": {"body": "Oi"}},
        headers={"Authorization": f"Bearer {settings.whatsapp_access_token}", "X-Cloudesk-Message-Id": "core-1"},
    )
    stream = await client.post("/chat/streams", json={"stream": "s-1", "app_user_id": "app-ana"})

    assert whatsapp.status == 200
    assert stream.status == 200
    assert read_jsonl(settings.data_dir / "received.jsonl")[0]["core_message_id"] == "core-1"
    assert read_jsonl(settings.data_dir / "streams.jsonl")[0]["app_user_id"] == "app-ana"


async def test_streams_registrados_sao_relidos_na_partida(aiohttp_client, settings):
    first = await aiohttp_client(create_app(settings, background=False))
    await first.post("/chat/streams", json={"stream": "s-1", "app_user_id": "app-ana"})
    await first.close()

    second = await aiohttp_client(create_app(settings, background=False))
    conflict = await second.post("/chat/streams", json={"stream": "s-1", "app_user_id": "app-bruno"})

    assert conflict.status == 409


async def test_rota_desconhecida(aiohttp_client, settings):
    client = await aiohttp_client(create_app(settings, background=False))

    response = await client.get("/nada")

    assert response.status == 404
