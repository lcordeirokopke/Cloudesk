import random

import pytest

from channel_simulator import templates


def sequence(seed: int, locale: str, count: int = 20, ratio: float = 0.5):
    rng = random.Random(seed)
    return [templates.generate(rng, locale, attachment_ratio=ratio) for _ in range(count)]


@pytest.mark.parametrize("locale", ["pt-BR", "en-US"])
def test_mesma_semente_gera_a_mesma_sequencia(locale):
    assert sequence(3, locale) == sequence(3, locale)
    assert sequence(3, locale) != sequence(4, locale)


@pytest.mark.parametrize("locale", ["pt-BR", "en-US"])
def test_cada_intencao_tem_tres_ou_mais_modelos(locale):
    assert set(templates.TEMPLATES[locale]) == set(templates.INTENTS)
    assert all(len(models) >= 3 for models in templates.TEMPLATES[locale].values())


@pytest.mark.parametrize("locale", ["pt-BR", "en-US"])
def test_respeita_o_locale(locale):
    prefixes = {model.split("{")[0] for models in templates.TEMPLATES[locale].values() for model in models}

    for content in sequence(5, locale, 50):
        assert any(content.text.startswith(prefix) for prefix in prefixes)
        assert content.subject == templates.SUBJECTS[locale][content.intent]


@pytest.mark.parametrize("locale", ["pt-BR", "en-US"])
def test_nenhum_texto_vazio_nem_campo_sem_preencher(locale):
    for content in sequence(9, locale, 200):
        assert content.text.strip()
        assert content.subject.strip()
        assert "{" not in content.text
        assert content.intent in templates.INTENTS


def test_intencao_informada():
    content = templates.generate(random.Random(1), "pt-BR", intent="repasse")

    assert content.intent == "repasse"
    assert content.subject == "Repasse não recebido"


def test_fracao_de_anexos():
    assert all(content.attachment is None for content in sequence(1, "pt-BR", 50, ratio=0.0))
    assert all(content.attachment is not None for content in sequence(1, "pt-BR", 50, ratio=1.0))


def test_anexos_sinteticos():
    rng = random.Random(1)
    image = templates.attachment("image", rng)
    document = templates.attachment("document", rng)

    assert image.metadata() == {
        "kind": "image", "filename": "comprovante.jpg", "content_type": "image/jpeg", "size": len(image.data)
    }
    assert image.data.startswith(b"\xff\xd8")
    assert document.filename == "extrato.pdf"
    assert document.content_type == "application/pdf"
    assert document.data.startswith(b"%PDF-")
    with pytest.raises(ValueError):
        templates.attachment("audio", rng)
