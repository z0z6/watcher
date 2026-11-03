"""Punkty schronienia z oficjalnego zbioru KG PSP ("Punkty schronienia w Polsce", dane.gov.pl, aktualizowany
w poniedziałki; ten sam plik zasila serwis gdziesieukryc.pl).

Plik CSV pobieramy po stronie serwera (GitHub Actions), bo przeglądarka/aplikacja nie dostanie go od PSP (CORS).
Nazwy kolumn ("Identyfikator publiczny", "Szerokosc geograficzna", "Dlugosc geograficzna", "Adres", "Gmina",
"Dostepnosc") pochodzą z kodu niezależnego projektu, który czyta ten plik (stan: 2026-11), a nie z własnych
testów na żywo - dlatego parser jest tolerancyjny na wielkość liter i polskie znaki, ale NIE zgaduje: przy
braku wymaganej kolumny kończy się błędem widocznym w source_status feedu.

Zbiór zawiera ~88 tys. punktów w całym kraju. Do feedu trafiają tylko punkty z obszaru monitorowania.
"""
from __future__ import annotations
import csv
import io
import json
import math
import re
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

import requests

from .geo import Powiaty, norm

SOURCE_URL = "https://gdziesieukryc.pl/PS_XML/punkty_schronienia.csv"
UA = {"User-Agent": "watchpl/0.4 (personal monitor)"}
AVAILABILITY = {"calodobowa": 0, "okreslone godziny": 1, "na zadanie": 2}   # 3 = nieznana wartość
REQUIRED = {"id": "identyfikator", "lat": "szerokosc", "lon": "dlugosc", "adres": "adres",
            "gmina": "gmina", "d": "dostepnosc"}


def region_bbox(powiaty: Powiaty, margin_deg: float = 0.1) -> tuple[float, float, float, float]:
    """(lat_min, lat_max, lon_min, lon_max) obejmujący wszystkie powiaty obszaru wraz z ich promieniami."""
    la0 = lo0 = 1e9
    la1 = lo1 = -1e9
    for p in powiaty.by_code.values():
        dl = p.radius_km / 111.0
        do = p.radius_km / (111.0 * math.cos(math.radians(p.lat)))
        la0, la1 = min(la0, p.lat - dl), max(la1, p.lat + dl)
        lo0, lo1 = min(lo0, p.lon - do), max(lo1, p.lon + do)
    return la0 - margin_deg, la1 + margin_deg, lo0 - margin_deg, lo1 + margin_deg


def _num(v: str) -> float | None:
    try:
        return float(str(v).strip().replace(",", "."))
    except ValueError:
        return None


def parse_csv(text: str, bbox: tuple[float, float, float, float]) -> tuple[dict, dict]:
    """Zwraca (zbiór w zapisie kolumnowym, statystyki). Rzuca ValueError przy braku wymaganej kolumny."""
    reader = csv.reader(io.StringIO(text.lstrip("\ufeff")))
    header = next(reader, None)
    if not header:
        raise ValueError("pusty plik CSV")
    nh = [norm(h).strip() for h in header]
    idx: dict[str, int] = {}
    for key, needle in REQUIRED.items():
        found = [i for i, h in enumerate(nh) if needle in h]
        if not found:
            raise ValueError(f"brak kolumny '{needle}' w CSV PSP (nagłówek: {header})")
        idx[key] = found[0]
    t_idx = next((i for i, h in enumerate(nh) if re.search(r"rodzaj|kategori|typ", h)), None)

    la0, la1, lo0, lo1 = bbox
    cols = {"id": [], "lat": [], "lon": [], "adres": [], "gmina": [], "d": []}
    if t_idx is not None:
        cols["t"] = []
    stats = {"rows": 0, "kept": 0, "bad_coords": 0, "unknown_availability": 0}
    for row in reader:
        if not row or len(row) <= max(idx.values()):
            continue
        stats["rows"] += 1
        lat, lon = _num(row[idx["lat"]]), _num(row[idx["lon"]])
        if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180):
            stats["bad_coords"] += 1
            continue
        if not (la0 <= lat <= la1 and lo0 <= lon <= lo1):
            continue
        d = AVAILABILITY.get(norm(row[idx["d"]]).strip(), 3)
        stats["unknown_availability"] += d == 3
        cols["id"].append(row[idx["id"]].strip())
        cols["lat"].append(round(lat, 6))
        cols["lon"].append(round(lon, 6))
        cols["adres"].append(row[idx["adres"]].strip())
        cols["gmina"].append(row[idx["gmina"]].strip())
        cols["d"].append(d)
        if t_idx is not None:
            cols["t"].append(row[t_idx].strip() if t_idx < len(row) else "")
        stats["kept"] += 1
    return cols, stats


def _stored(out: Path) -> dict | None:
    f = out / "shelters.json"
    try:
        return json.loads(f.read_text(encoding="utf-8")) if f.exists() else None
    except ValueError:
        return None


def refresh(out: Path, now: datetime, powiaty: Powiaty, session=requests) -> str:
    """Pobiera zbiór tylko gdy się zmienił (Last-Modified) albo plik jest starszy niż 7 dni.
    Zwraca opis do source_status. Błędy NIE przerywają budowy feedu (łapie je wywołujący)."""
    old = _stored(out)
    last_mod = None
    try:
        h = session.head(SOURCE_URL, headers=UA, timeout=20, allow_redirects=True)
        last_mod = h.headers.get("Last-Modified")
    except requests.RequestException:
        pass
    if old and not old.get("demo"):
        fresh = datetime.fromisoformat(old["fetched_at"]) > now - timedelta(days=7)
        if (last_mod and old.get("last_modified") == last_mod) or (not last_mod and fresh):
            return f"bez zmian ({old['n']} punktów, stan {old['stan']})"
    r = session.get(SOURCE_URL, headers=UA, timeout=120)
    r.raise_for_status()
    last_mod = r.headers.get("Last-Modified", last_mod)
    cols, stats = parse_csv(r.content.decode("utf-8-sig"), region_bbox(powiaty))
    if stats["kept"] == 0:
        raise ValueError(f"po filtrze obszaru 0 punktów (wierszy w pliku: {stats['rows']})")
    stan = (parsedate_to_datetime(last_mod).astimezone(timezone.utc) if last_mod else now).date().isoformat()
    doc = {"source": SOURCE_URL, "dataset": "https://dane.gov.pl/pl/dataset/28058,punkty-schronienia-w-polsce",
           "license": "CC BY 4.0 (wg opisu zbioru) - Komenda Główna PSP, dane.gov.pl",
           "stan": stan, "last_modified": last_mod, "fetched_at": now.isoformat(), "n": stats["kept"], **cols}
    (out / "shelters.json").write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    extra = f", nieznana dostępność: {stats['unknown_availability']}" if stats["unknown_availability"] else ""
    extra += f", złe współrzędne: {stats['bad_coords']}" if stats["bad_coords"] else ""
    return f"ok ({stats['kept']} z {stats['rows']} punktów, stan {stan}{extra})"


def demo_shelters(out: Path, now: datetime, places) -> str:
    """Punkty wymyślone (DEMO=1), żeby zobaczyć interfejs przed pierwszym prawdziwym pobraniem."""
    cols = {"id": [], "lat": [], "lon": [], "adres": [], "gmina": [], "d": []}
    offs = [(0.004, 0.003, 0), (-0.003, 0.006, 1), (0.007, -0.004, 2), (-0.006, -0.005, 0)]
    for p in places:
        for k, (dy, dx, d) in enumerate(offs):
            cols["id"].append(f"DEMO-{p.name[:3].upper()}-{k}")
            cols["lat"].append(round(p.lat + dy, 6))
            cols["lon"].append(round(p.lon + dx, 6))
            cols["adres"].append(f"ul. Demonstracyjna {k + 1}, {p.name}")
            cols["gmina"].append(p.name)
            cols["d"].append(d)
    doc = {"source": "demo", "dataset": "", "license": "dane demonstracyjne", "demo": True,
           "stan": now.date().isoformat(), "last_modified": None, "fetched_at": now.isoformat(),
           "n": len(cols["id"]), **cols}
    (out / "shelters.json").write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    return f"demo ({doc['n']} punktów)"
