"""Obiekty o znaczeniu strategicznym w kryzysie (apteki, stacje paliw, szpitale, szkoły, mosty, jednostki wojskowe)
z OpenStreetMap przez Overpass API (bez klucza). Pobierane raz na tydzień po stronie serwera (GitHub Actions),
zapisywane jako poi.json obok feed.json; aplikacja trzyma kopię w telefonie.

Dane OSM tworzy społeczność: kompletność i aktualność bywają różne (zwłaszcza obiekty wojskowe i mosty),
a część obiektów może nie być zmapowana. Licencja: ODbL, (c) autorzy OpenStreetMap.

Zapytania ograniczone do granic Polski (area ISO3166-1=PL), bo prostokąt obszaru NE obejmuje też Białoruś,
Litwę i obwód królewiecki. Kategorie pobieramy osobno: błąd jednej nie psuje pozostałych, a dla nieudanej
zostaje poprzednia wersja danych.
"""
from __future__ import annotations
import json
import time
from datetime import datetime, timedelta
from pathlib import Path

import requests

from .geo import Powiaty, haversine_km
from .shelters import region_bbox

ENDPOINTS = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter"]
UA = {"User-Agent": "watchpl/0.5 (personal monitor; GitHub Actions, weekly)"}
CATEGORIES = ("pharmacy", "fuel", "hospital", "school", "bridge", "military")
DEFAULT_NAME = {"pharmacy": "Apteka", "fuel": "Stacja paliw", "hospital": "Szpital", "school": "Szkoła",
                "bridge": "Most", "military": "Obiekt wojskowy"}
MIN_BRIDGE_M = 40          # krótsze mosty bez nazwy to zwykle przepusty
MILITARY_RE = "^(barracks|base|airfield|naval_base|training_area|range|checkpoint)$"
BRIDGE_ROADS = "^(motorway|trunk|primary|secondary)$"

BODY = {
    "pharmacy": 'nwr["amenity"="pharmacy"](area.pl){b};',
    "fuel": 'nwr["amenity"="fuel"](area.pl){b};',
    "hospital": 'nwr["amenity"="hospital"](area.pl){b};nwr["healthcare"="hospital"]["amenity"!="hospital"](area.pl){b};',
    "school": 'nwr["amenity"="school"](area.pl){b};',
    "bridge": 'way["bridge"="yes"]["highway"~"' + BRIDGE_ROADS + '"](area.pl){b};',
    "military": ('nwr["military"~"' + MILITARY_RE + '"](area.pl){b};nwr["office"="military"](area.pl){b};'
                 'nwr["landuse"="military"]["name"](area.pl){b};'),
}
OUT_MODE = {c: "center tags" for c in CATEGORIES} | {"bridge": "tags bb"}   # mosty: ramka -> długość


def build_query(cat: str, bbox: tuple[float, float, float, float]) -> str:
    la0, la1, lo0, lo1 = bbox
    b = f"({la0:.3f},{lo0:.3f},{la1:.3f},{lo1:.3f})"
    return (f'[out:json][timeout:120];area["ISO3166-1"="PL"][admin_level=2]->.pl;'
            f'({BODY[cat].replace("{b}", b)});out {OUT_MODE[cat]};')


def _point(el: dict) -> tuple[float, float] | None:
    if "lat" in el and "lon" in el:
        return float(el["lat"]), float(el["lon"])
    c = el.get("center")
    if c:
        return float(c["lat"]), float(c["lon"])
    b = el.get("bounds")
    if b:
        return (b["minlat"] + b["maxlat"]) / 2, (b["minlon"] + b["maxlon"]) / 2
    return None


def _bridge_length_m(el: dict) -> float:
    b = el.get("bounds")
    return haversine_km(b["minlat"], b["minlon"], b["maxlat"], b["maxlon"]) * 1000 if b else 0.0


ROAD = {"motorway": "autostrada", "trunk": "droga ekspresowa/krajowa", "primary": "droga krajowa",
        "secondary": "droga wojewódzka"}
MIL = {"barracks": "koszary", "base": "baza wojskowa", "airfield": "lotnisko wojskowe", "naval_base": "baza morska",
       "training_area": "poligon", "range": "strzelnica", "checkpoint": "punkt kontrolny"}


def _extra(cat: str, tags: dict, el: dict) -> str:
    oh = tags.get("opening_hours", "")
    if cat == "pharmacy":
        return "całodobowa" if oh == "24/7" else oh[:60]
    if cat == "fuel":
        parts = [tags.get("brand") or tags.get("operator") or ""]
        if oh == "24/7":
            parts.append("całodobowo")
        if tags.get("fuel:lpg") == "yes":
            parts.append("LPG")
        return ", ".join(p for p in parts if p)
    if cat == "hospital":
        return "izba przyjęć/SOR" if tags.get("emergency") == "yes" else ""
    if cat == "bridge":
        n = round(_bridge_length_m(el))
        return ", ".join(x for x in (tags.get("ref", ""), ROAD.get(tags.get("highway", ""), ""), f"~{n} m" if n else "") if x)
    if cat == "military":
        return MIL.get(tags.get("military", ""), "instytucja wojskowa" if tags.get("office") == "military" else "teren wojskowy")
    return ""


def build_category(cat: str, elements: list[dict]) -> dict:
    """Elementy Overpass -> zapis kolumnowy {n, lat, lon, name, x}. Deduplikacja i filtr zbyt krótkich mostów."""
    cols = {"lat": [], "lon": [], "name": [], "x": []}
    seen: set = set()
    for el in elements:
        pt = _point(el)
        if pt is None:
            continue
        tags = el.get("tags") or {}
        name = (tags.get("name") or "").strip()
        if cat == "bridge" and not name and _bridge_length_m(el) < MIN_BRIDGE_M:
            continue
        digits = 3 if cat == "bridge" else 4          # most dwujezdniowy to dwa elementy: ~100 m tolerancji
        key = (round(pt[0], digits), round(pt[1], digits), name if cat != "bridge" else tags.get("ref", name))
        if key in seen:
            continue
        seen.add(key)
        cols["lat"].append(round(pt[0], 6))
        cols["lon"].append(round(pt[1], 6))
        cols["name"].append(name or DEFAULT_NAME[cat])
        cols["x"].append(_extra(cat, tags, el))
    return {"n": len(cols["lat"]), **cols}


def _fetch(cat: str, bbox, session, sleep) -> list[dict]:
    q = build_query(cat, bbox)
    last: Exception | None = None
    for attempt in range(3):
        url = ENDPOINTS[attempt % len(ENDPOINTS)]       # przy 429/5xx przełączamy lustro
        try:
            r = session.post(url, data={"data": q}, headers=UA, timeout=180)
            if r.status_code in (429, 502, 503, 504):
                raise requests.HTTPError(f"HTTP {r.status_code}")
            r.raise_for_status()
            js = r.json()
            if "error" in str(js.get("remark", "")).lower():    # Overpass zgłasza przekroczenie czasu w polu remark
                raise requests.HTTPError("Overpass: " + str(js["remark"])[:80])
            return js.get("elements", [])
        except (requests.RequestException, ValueError) as ex:
            last = ex
            sleep(10)
    raise RuntimeError(f"{cat}: {type(last).__name__}: {str(last)[:100]}")


def _stored(out: Path) -> dict | None:
    f = out / "poi.json"
    try:
        return json.loads(f.read_text(encoding="utf-8")) if f.exists() else None
    except ValueError:
        return None


def refresh(out: Path, now: datetime, powiaty: Powiaty, session=requests, sleep=time.sleep, max_age_days: int = 7,
            retry_after_hours: int = 6) -> str:
    old = _stored(out)
    if (old and not old.get("demo") and set(CATEGORIES) <= set(old.get("cats", {}))
            and not old.get("errors") and datetime.fromisoformat(old["fetched_at"]) > now - timedelta(days=max_age_days)):
        return "bez zmian (" + ", ".join(f"{c}: {old['cats'][c]['n']}" for c in CATEGORIES) + ")"
    if (old and not old.get("demo") and old.get("errors")
            and datetime.fromisoformat(old["fetched_at"]) > now - timedelta(hours=retry_after_hours)):
        # po błędach nie ponawiamy co 15 minut: publiczny Overpass jest wspólnym zasobem
        return f"ponowna próba po {retry_after_hours} h od ostatniej (błędy: {', '.join(old['errors'])})"
    bbox = region_bbox(powiaty)
    cats = dict((old or {}).get("cats", {})) if not (old or {}).get("demo") else {}
    errors: dict[str, str] = {}
    for i, cat in enumerate(CATEGORIES):
        if i:
            sleep(5)                                    # grzeczność wobec publicznego Overpass
        try:
            cats[cat] = build_category(cat, _fetch(cat, bbox, session, sleep))
        except Exception as ex:  # noqa: BLE001
            errors[cat] = str(ex)[:140]
    if not cats:
        raise RuntimeError("; ".join(errors.values()) or "brak danych")
    doc = {"source": "OpenStreetMap (Overpass API)", "license": "ODbL, (c) autorzy OpenStreetMap",
           "fetched_at": now.isoformat(), "errors": errors, "cats": cats}
    (out / "poi.json").write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    summary = ", ".join(f"{c}: {cats[c]['n']}" for c in CATEGORIES if c in cats)
    return f"ok ({summary})" + (f"; błędy: {', '.join(errors)}" if errors else "")


def demo_poi(out: Path, now: datetime, places) -> str:
    cats = {c: {"n": 0, "lat": [], "lon": [], "name": [], "x": []} for c in CATEGORIES}
    spots = {"pharmacy": (0.002, 0.004, "całodobowa"), "fuel": (-0.004, 0.002, "Orlen, całodobowo"),
             "hospital": (0.006, -0.003, "izba przyjęć/SOR"), "school": (-0.002, -0.005, ""),
             "bridge": (0.008, 0.006, "DK, ~120 m"), "military": (-0.009, 0.008, "koszary")}
    for p in places:
        for cat, (dy, dx, x) in spots.items():
            c = cats[cat]
            c["lat"].append(round(p.lat + dy, 6))
            c["lon"].append(round(p.lon + dx, 6))
            c["name"].append(f"{DEFAULT_NAME[cat]} (demo) {p.name}")
            c["x"].append(x)
            c["n"] += 1
    doc = {"source": "demo", "license": "dane demonstracyjne", "demo": True, "fetched_at": now.isoformat(),
           "errors": {}, "cats": cats}
    (out / "poi.json").write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    return f"demo ({sum(c['n'] for c in cats.values())} obiektów)"
