import random

import pytest

from channel_simulator import personas


def test_le_o_arquivo_de_personas(personas_path):
    loaded = personas.load(personas_path)

    assert [brand.slug for brand in loaded.brands] == ["infinitepay", "jim"]
    infinitepay = loaded.brand("infinitepay")
    assert infinitepay.locale == "pt-BR"
    assert infinitepay.whatsapp_numbers[0] == personas.WhatsappNumber("110000000000001", "551140000001")
    assert infinitepay.support_emails == ("financeiro@infinitepay.test", "suporte@infinitepay.test")
    assert infinitepay.contacts[0] == personas.Contact("Ana Lima", "+5511912345678", "ana.lima@example.com", "app-ana")
    assert infinitepay.contacts[0].origin == "seed"


def test_identidade_por_canal(personas_path):
    contact = personas.load(personas_path).brand("jim").contacts[0]

    assert contact.identity("whatsapp") == "+12125551234"
    assert contact.identity("email") == "alice.baker@example.com"
    assert contact.identity("chat") == "app-alice"


def test_marca_desconhecida(personas_path):
    with pytest.raises(KeyError):
        personas.load(personas_path).brand("outra")


def test_arquivo_ausente_explica_como_gerar(tmp_path):
    with pytest.raises(FileNotFoundError, match="simulator:personas"):
        personas.load(tmp_path / "personas.json")


def test_lojistas_novos_sao_deterministicos_para_a_mesma_semente(personas_path):
    brand = personas.load(personas_path).brand("infinitepay")
    rng_a, rng_b = random.Random(42), random.Random(42)

    generated_a = [personas.new_contact(brand, rng_a) for _ in range(5)]
    generated_b = [personas.new_contact(brand, rng_b) for _ in range(5)]
    other_seed = personas.new_contact(brand, random.Random(7))

    assert generated_a == generated_b
    assert len({contact.whatsapp for contact in generated_a}) == 5
    assert other_seed != generated_a[0]


@pytest.mark.parametrize(("slug", "prefix", "length"), [("infinitepay", "+55", 14), ("jim", "+1", 12)])
def test_lojista_novo_tem_o_codigo_do_pais_da_marca(personas_path, slug, prefix, length):
    brand = personas.load(personas_path).brand(slug)

    contact = personas.new_contact(brand, random.Random(1))

    assert contact.whatsapp.startswith(prefix)
    assert contact.whatsapp[1:].isdigit()
    assert len(contact.whatsapp) == length
    assert contact.email.endswith("@example.com")
    assert contact.chat.startswith("app-sim-")
    assert contact.origin == "new"
