"""Klastrowanie twierdzeń w zdarzenia i ocena wiarygodności (twarde sygnały, nie model)."""
from __future__ import annotations
import hashlib
import re
from collections import defaultdict
from datetime import datetime, timedelta

from .geo import norm
from .models import SOURCE_WEIGHT, Claim

HARD_TYPES = {"power"}          # typy, dla których operator publikuje dane
WINDOW = timedelta(hours=6)
FRESH_MIN = 30                  # świeże zdarzenie: dane operatora mogą mieć opóźnienie
LABEL = {"power": "brak prądu", "water": "awaria wody", "weather": "zagrożenie pogodowe",
         "disaster": "klęska żywiołowa", "infrastructure": "awaria infrastruktury",
         "epidemic": "zagrożenie epidemiologiczne", "unrest": "niepokoje",
         "shortage": "braki w sklepach", "sabotage": "podejrzenie sabotażu", "other": "zdarzenie"}


def _tokens(t: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]{3,}", norm(t)))


def _jaccard(a: set, b: set) -> float:
    u = a | b
    return len(a & b) / len(u) if u else 0.0


def _origins(claims: list[Claim]) -> list[list[Claim]]:
    """Grupuje twierdzenia w niezależne 'pochodzenia': to samo źródło albo przeklejony tekst = jedno."""
    parent = list(range(len(claims)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    toks = [_tokens(c.item.text) for c in claims]
    for i in range(len(claims)):
        for j in range(i + 1, len(claims)):
            if (claims[i].item.source_id == claims[j].item.source_id
                    or _jaccard(toks[i], toks[j]) >= 0.7):
                parent[find(j)] = find(i)
    groups = defaultdict(list)
    for i, c in enumerate(claims):
        groups[find(i)].append(c)
    return list(groups.values())


def verdict_for(cred: int) -> str:
    return "likely" if cred >= 75 else "unverified" if cred >= 40 else "dubious"


def _make(cs: list[Claim], official_ok: dict[str, bool], now: datetime) -> dict:
    place, typ = cs[0].place, cs[0].type
    origins = _origins(cs)
    p_false = 1.0
    for o in origins:
        p_false *= 1 - max(SOURCE_WEIGHT[c.item.kind] for c in o)
    cred = round((1 - p_false) * 100)

    first = min(c.item.published for c in cs)
    last = max(c.item.published for c in cs)
    age_min = (now - first).total_seconds() / 60
    official = any(c.item.kind == "official" for c in cs)
    reasons: list[str] = []

    if official:
        cred, verdict = max(cred, 90), "confirmed"
        reasons.append("Potwierdzone w oficjalnym źródle")
    else:
        n = len(origins)
        reasons.append("Tylko 1 niezależne źródło" if n == 1 else f"{n} niezależnych źródeł")
        if typ in HARD_TYPES and official_ok.get(typ):
            if age_min >= FRESH_MIN:
                cred = min(cred, 35)
                reasons.append("Brak wpisu w danych operatora, mimo że dane działają")
            else:
                reasons.append("Zdarzenie świeże - dane operatora mogą mieć opóźnienie")
        for o in origins:
            srcs = {c.item.source_id for c in o}
            if len(srcs) >= 3:
                reasons.append(f"Ten sam tekst w {len(srcs)} miejscach (przeklejanie lub koordynacja)")
        if all(SOURCE_WEIGHT[c.item.kind] <= 0.25 for c in cs):
            reasons.append("Wyłącznie źródła niskiej wiarygodności (social/agregatory)")
        verdict = verdict_for(cred)

    attribution = any(c.attribution_claimed for c in cs)
    if attribution and not any(c.item.kind == "official" and c.attribution_claimed for c in cs):
        reasons.append("Wątek sabotażu/ataku bez potwierdzenia służb")

    best = max(cs, key=lambda c: SOURCE_WEIGHT[c.item.kind])
    # źródła z linkiem do konkretnego artykułu/komunikatu: najpierw najwiarygodniejsze, potem najnowsze
    seen: dict[str, dict] = {}
    for c in sorted(cs, key=lambda c: (-SOURCE_WEIGHT[c.item.kind], -c.item.published.timestamp())):
        u = c.item.url or c.item.source_id
        seen.setdefault(u, {"name": c.item.source_name, "url": c.item.url, "kind": c.item.kind,
                            "title": c.item.title or c.item.text[:100],
                            "published": c.item.published.isoformat()})
    keyed = next((c for c in cs if c.key), None)
    stable = keyed.key if keyed else f"{first:%Y%m%d}"   # dzień, nie godzina: stabilne id między uruchomieniami
    eid = hashlib.sha1(f"{place.name}|{typ}|{stable}".encode()).hexdigest()[:12]
    labelled = next((c.label for c in cs if c.label), None)
    valid_to = max((c.valid_to for c in cs if c.valid_to), default=None)
    return {
        "id": eid, "type": typ, "severity": max(c.severity for c in cs),
        "place": place.name, "powiat": place.powiat, "powiat_slug": place.powiat_slug,
        "lat": place.lat, "lon": place.lon, "radius_km": place.radius_km,
        "valid_to": valid_to.isoformat() if valid_to else None,
        "first_seen": first.isoformat(), "last_seen": last.isoformat(),
        "credibility": cred, "verdict": verdict, "attribution_claimed": attribution,
        "summary": f"{place.name}: {labelled or LABEL.get(typ, 'zdarzenie')}",
        "snippet": best.item.text[:200], "reasons": reasons, "sources": list(seen.values())[:8],
    }


def build_events(claims: list[Claim], official_ok: dict[str, bool], now: datetime) -> list[dict]:
    buckets = defaultdict(list)
    for c in claims:
        buckets[(c.place.name, c.type, c.key or "")].append(c)
    events = []
    for cs in buckets.values():
        cs.sort(key=lambda c: c.item.published)
        cluster = [cs[0]]
        for c in cs[1:]:
            if c.item.published - cluster[-1].item.published > WINDOW:
                events.append(_make(cluster, official_ok, now))
                cluster = [c]
            else:
                cluster.append(c)
        events.append(_make(cluster, official_ok, now))
    return sorted(events, key=lambda e: (-e["severity"], -e["credibility"]))
