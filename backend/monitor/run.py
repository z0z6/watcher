from __future__ import annotations
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
import yaml

from .demo import demo_items
from .extract import extract
from .geo import Gazetteer, Powiaty
from .score import build_events, LABEL
from .sources import collect
from .verify import verify_events
from . import poi, shelters

ROOT = Path(__file__).resolve().parent.parent
COVERAGE = {  # statyczny opis pokrycia - pokazywany w aplikacji ("brak alertu != spokój")
    "weather": "good", "disaster": "partial", "power": "partial", "water": "partial",
    "infrastructure": "weak", "epidemic": "weak", "unrest": "weak", "shortage": "weak",
}


def notify(events: list[dict], state: dict) -> None:
    """Opcjonalny push przez ntfy: temat na powiat, tylko ważne i niepodejrzane zdarzenia."""
    prefix = os.environ.get("NTFY_PREFIX")
    if not prefix:
        return
    sent = state.setdefault("notified", [])
    for e in events:
        key = f"{e['id']}:{e['verdict']}"
        if e["severity"] >= 4 and e["verdict"] != "dubious" and key not in sent:
            body = {"topic": f"{prefix}-{e['powiat_slug']}", "title": e["summary"],
                    "message": f"{e['verdict']} ({e['credibility']}%). " + "; ".join(e["reasons"][:2]),
                    "priority": 4, "tags": ["warning"]}
            if e["sources"] and e["sources"][0].get("url", "").startswith("https://"):
                body["click"] = e["sources"][0]["url"]     # dotknięcie powiadomienia otwiera źródło
            try:
                requests.post("https://ntfy.sh/", json=body, timeout=10).raise_for_status()
                sent.append(key)
            except requests.RequestException as ex:
                print(f"[ntfy] {ex}", file=sys.stderr)
    state["notified"] = sent[-500:]


def drop_weather_news(news: list, cfg: dict) -> list:
    """Pogodę podają ostrzeżenia IMGW (oficjalne, z datami ważności). Pogoda "z wiadomości" to głównie
    przedruki, felietony i dawne zdarzenia, więc domyślnie jej nie bierzemy (weather_from_news: true włącza)."""
    return news if cfg.get("weather_from_news", False) else [c for c in news if c.type != "weather"]


def load_state(out: Path) -> dict:
    f = out / "state.json"
    try:
        return json.loads(f.read_text()) if f.exists() else {}
    except ValueError:
        return {}


def fresh_items(items, now: datetime, max_age_h: float):
    """Twarda świeżość: pozycje bez daty albo starsze niż max_age_h odpadają."""
    limit = now - timedelta(hours=max_age_h)
    return [i for i in items if limit <= i.published <= now + timedelta(hours=2)]


def probe(cfg, gaz, powiaty, now) -> None:
    """Diagnostyka: pobiera każde włączone źródło i wypisuje, co z niego wyszło."""
    items, claims, official_ok, status = collect(cfg, gaz, powiaty, now)
    print("STATUS:", json.dumps(status, ensure_ascii=False, indent=1))
    for c in claims[:5]:
        print("CLAIM:", c.place.name, c.type, c.severity, c.label)
    for it in items[:5]:
        print("ITEM:", it.source_name, it.kind, it.text[:100])
    print(f"claims={len(claims)} items={len(items)}")


def main() -> None:
    out = Path(os.environ.get("OUT_DIR", "out"))
    out.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc)
    gaz = Gazetteer.load(ROOT / "data" / "places.csv")
    powiaty = Powiaty(ROOT / "data" / "powiaty.csv")

    if "--probe" in sys.argv:
        cfg = yaml.safe_load((ROOT / "sources.yaml").read_text(encoding="utf-8"))
        return probe(cfg, gaz, powiaty, now)
    cfg = yaml.safe_load((ROOT / "sources.yaml").read_text(encoding="utf-8"))
    if os.environ.get("DEMO") == "1":
        items, claims, official_ok = demo_items(now, powiaty)
        status = {"demo": "ok"}
    else:
        items, claims, official_ok, status = collect(cfg, gaz, powiaty, now)

    max_age = float(cfg.get("max_age_hours", 36)) if os.environ.get("DEMO") != "1" else 1e6
    items = fresh_items(items, now, max_age)
    claims = claims + drop_weather_news(extract(items, gaz, now), cfg)
    events = [e for e in build_events(claims, official_ok, now)
              if (e["valid_to"] and datetime.fromisoformat(e["valid_to"]) > now)
              or datetime.fromisoformat(e["last_seen"]) > now - timedelta(hours=max_age)]
    state = load_state(out)
    client = None
    if os.environ.get("ANTHROPIC_API_KEY") and os.environ.get("VERIFY", "1") == "1":
        try:
            import anthropic
            client = anthropic.Anthropic()
        except Exception as ex:  # noqa: BLE001
            print(f"[verify] brak klienta: {ex}", file=sys.stderr)
    verify_events(events, state, now, client)
    try:
        status["shelters"] = (shelters.demo_shelters(out, now, gaz.places) if os.environ.get("DEMO") == "1"
                              else shelters.refresh(out, now, powiaty))
    except Exception as ex:  # noqa: BLE001   błąd schronów nie może zatrzymać feedu zdarzeń
        status["shelters"] = f"błąd: {type(ex).__name__}: {str(ex)[:160]}"
        print(f"[shelters] {ex}", file=sys.stderr)
    try:
        status["poi"] = (poi.demo_poi(out, now, gaz.places) if os.environ.get("DEMO") == "1"
                         else poi.refresh(out, now, powiaty))
    except Exception as ex:  # noqa: BLE001   błąd obiektów OSM nie może zatrzymać feedu zdarzeń
        status["poi"] = f"błąd: {type(ex).__name__}: {str(ex)[:160]}"
        print(f"[poi] {ex}", file=sys.stderr)
    feed = {"generated_at": now.isoformat(), "events": events,
            "coverage": {**COVERAGE, "power": "good" if official_ok.get("power") else COVERAGE["power"],
                         "power_live": bool(official_ok.get("power"))},
            "source_status": status, "labels": LABEL}
    notify(events, state)
    (out / "state.json").write_text(json.dumps(state), encoding="utf-8")
    (out / "feed.json").write_text(json.dumps(feed, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"events={len(events)} status={status}")


if __name__ == "__main__":
    main()
