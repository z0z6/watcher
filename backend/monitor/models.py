from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime

EVENT_TYPES = ("power", "water", "unrest", "shortage", "sabotage", "other")

# Waga = prawdopodobieństwo, że pojedyncze niezależne źródło tego rodzaju mówi prawdę.
# To heurystyka startowa - dostrajaj na podstawie własnych obserwacji.
SOURCE_WEIGHT = {
    "official": 1.0,        # operator sieci, służby, gmina, wodociągi
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
    attribution_claimed: bool  # tekst przypisuje zdarzenie sabotażowi/atakowi
