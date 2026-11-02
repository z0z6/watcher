from __future__ import annotations
import csv
import math
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path


def norm(s: str) -> str:
    s = s.lower().replace("ł", "l")
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c))


def haversine_km(lat1, lon1, lat2, lon2) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


@dataclass(frozen=True)
class Place:
    name: str
    powiat: str
    woj: str
    lat: float
    lon: float

    @property
    def powiat_slug(self) -> str:
        return re.sub(r"[^a-z0-9]+", "-", norm(self.powiat)).strip("-")


def _stem_regex(name: str):
    """Odmiana polska zmienia końcówki (Mława -> w Mławie), więc dopasowujemy temat słowa."""
    parts, total = [], 0
    for w in norm(name).split():
        k = len(w) if len(w) <= 4 else max(4, len(w) - 2)
        parts.append(re.escape(w[:k]) + r"\w*")
        total += k
    return re.compile(r"\b" + r"\s+".join(parts)), total


class Gazetteer:
    def __init__(self, places: list[Place]):
        self.places = places
        self._rx = [(p, *_stem_regex(p.name)) for p in places]

    @classmethod
    def load(cls, path: str | Path) -> "Gazetteer":
        with open(path, encoding="utf-8") as f:
            rows = [Place(r["name"], r["powiat"], r["woj"], float(r["lat"]), float(r["lon"]))
                    for r in csv.DictReader(f)]
        return cls(rows)

    def find_in_text(self, text: str) -> Place | None:
        t = norm(text)
        best, best_len = None, 0
        for p, rx, ln in self._rx:
            if rx.search(t) and ln > best_len:  # dłuższy temat wygrywa (Ostrołęka vs Ostróda)
                best, best_len = p, ln
        return best

    def find(self, name: str | None) -> Place | None:
        return self.find_in_text(name) if name else None
