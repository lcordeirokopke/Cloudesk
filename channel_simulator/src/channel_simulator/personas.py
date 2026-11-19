"""Lojistas e canais das marcas.

Os lojistas das seeds vêm do personas.json exportado pela task simulator:personas do Core. Os
lojistas novos têm identidades aleatórias geradas por random.Random(seed): a mesma semente gera os
mesmos lojistas. O telefone segue o código do país da marca, pelo locale.
"""

import json
import random
from dataclasses import dataclass
from pathlib import Path

COUNTRY_CODES = {"pt-BR": "+55", "en-US": "+1"}

FIRST_NAMES = {
    "pt-BR": ["Ana", "Bruno", "Carla", "Diego", "Elisa", "Fábio", "Gabriela", "Heitor", "Isabela", "João"],
    "en-US": ["Alice", "Brian", "Chloe", "David", "Emma", "Frank", "Grace", "Henry", "Ivy", "Jack"],
}
LAST_NAMES = {
    "pt-BR": ["Almeida", "Barbosa", "Cardoso", "Duarte", "Esteves", "Ferreira", "Gomes", "Lima", "Moraes", "Nunes"],
    "en-US": ["Adams", "Baker", "Carter", "Dawson", "Ellis", "Foster", "Griffin", "Hayes", "Irwin", "Jensen"],
}

ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"


@dataclass(frozen=True)
class WhatsappNumber:
    phone_number_id: str
    display: str


@dataclass(frozen=True)
class Contact:
    name: str
    whatsapp: str
    email: str
    chat: str
    origin: str = "seed"

    def identity(self, channel: str) -> str:
        return {"whatsapp": self.whatsapp, "email": self.email, "chat": self.chat}[channel]


@dataclass(frozen=True)
class Brand:
    slug: str
    locale: str
    whatsapp_numbers: tuple[WhatsappNumber, ...]
    support_emails: tuple[str, ...]
    contacts: tuple[Contact, ...]

    @property
    def country_code(self) -> str:
        return COUNTRY_CODES[self.locale]


@dataclass(frozen=True)
class Personas:
    brands: tuple[Brand, ...]

    def brand(self, slug: str) -> Brand:
        for brand in self.brands:
            if brand.slug == slug:
                return brand
        raise KeyError(f"marca desconhecida: {slug}")


def load(path: Path) -> Personas:
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(
            f"{path} não existe; rode docker compose exec web bin/rails simulator:personas"
        )

    data = json.loads(path.read_text(encoding="utf-8"))
    return Personas(
        brands=tuple(
            Brand(
                slug=brand["slug"],
                locale=brand["locale"],
                whatsapp_numbers=tuple(
                    WhatsappNumber(number["phone_number_id"], number["display"]) for number in brand["whatsapp_numbers"]
                ),
                support_emails=tuple(brand["support_emails"]),
                contacts=tuple(
                    Contact(contact["name"], contact["whatsapp"], contact["email"], contact["chat"])
                    for contact in brand["contacts"]
                ),
            )
            for brand in data["brands"]
        )
    )


def _token(rng: random.Random, length: int) -> str:
    return "".join(rng.choice(ID_ALPHABET) for _ in range(length))


def new_contact(brand: Brand, rng: random.Random) -> Contact:
    """Lojista novo, desconhecido do Core, com identidades geradas por rng."""
    name = f"{rng.choice(FIRST_NAMES[brand.locale])} {rng.choice(LAST_NAMES[brand.locale])}"
    if brand.country_code == "+55":
        phone = f"+55{rng.choice(['11', '21', '31', '41', '51'])}9{rng.randrange(10**7, 10**8)}"
    else:
        phone = f"+1{rng.choice(['212', '305', '415', '512', '617'])}{rng.randrange(10**6, 10**7)}"
    token = _token(rng, 12)

    return Contact(
        name=name,
        whatsapp=phone,
        email=f"sim.{token}@example.com",
        chat=f"app-sim-{token}",
        origin="new",
    )
