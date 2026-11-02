from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime

# Typy zdarzeń. W aplikacji są pogrupowane w 6 przełączników (patrz app/lib/models.dart).
EVENT_TYPES = ("power", "water", "weather", "disaster", "infrastructure", "epidemic",
               "unrest", "shortage", "sabotage", "other")

# Waga = prawdopodobieństwo, że pojedyncze niezależne źródło tego rodzaju mówi prawdę.
# Heurystyka startowa - dostrajaj na podstawie własnych obserwacji.
SOURCE_WEIGHT = {
    "official": 1.0,        # IMGW, operator sieci, służby, gmina, wodociągi
    "media_national": 0.7,
    "media_local": 0.6,
    "social": 0.25,
    "aggregator": 0.2,      # mapy-agregatory (rybar, liveuamap itp.)
}


@dataclass
class RawItem:
    source_id: str
    source_name: str
    kind: str
    url: str
    text: str
    published: datetime


@dataclass
class Claim:
    item: RawItem
    place: "Place"  # noqa: F821
    type: str
    severity: int
    attribution_claimed: bool = False   # tekst przypisuje zdarzenie sabotażowi/atakowi
    label: str | None = None            # gotowy opis (np. z IMGW: "Silny wiatr, stopień 2")
    key: str | None = None              # stabilny identyfikator (np. ostrzeżenie IMGW)
    valid_to: datetime | None = None    # do kiedy obowiązuje (ostrzeżenia)
