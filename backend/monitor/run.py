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
from .geo import Gazetteer
from .score import build_events, LABEL
from .sources import collect

ROOT = Path(__file__).resolve().parent.parent
COVERAGE = {  # statyczny opis pokrycia - pokazywany w aplikacji ("brak alertu != spokój")
    "power": "good", "water": "partial", "unrest": "weak", "shortage": "weak", "sabotage": "weak",
}


def notify(events: list[dict], out: Path) -> None:
    """Opcjonalny push przez ntfy: temat na powiat, tylko ważne i niepodejrzane zdarzenia."""
    prefix = os.environ.get("NTFY_PREFIX")
    if not prefix:
        return
    state_f = out / "state.json"
    state = json.loads(state_f.read_text()) if state_f.exists() else {"notified": []}
    for e in events:
        key = f"{e['id']}:{e['verdict']}"
        if e["severity"] >= 4 and e["verdict"] != "dubious" and key not in state["notified"]:
            body = {"topic": f"{prefix}-{e['powiat_slug']}", "title": e["summary"],
                    "message": f"{e['verdict']} ({e['credibility']}%). " + "; ".join(e["reasons"][:2]),
                    "priority": 4, "tags": ["warning"]}
            try:
                requests.post("https://ntfy.sh/", json=body, timeout=10).raise_for_status()
                state["notified"].append(key)
            except requests.RequestException as ex:
                print(f"[ntfy] {ex}", file=sys.stderr)
    state["notified"] = state["notified"][-500:]
    state_f.write_text(json.dumps(state))


def main() -> None:
    out = Path(os.environ.get("OUT_DIR", "out"))
    out.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc)
    gaz = Gazetteer.load(ROOT / "data" / "places.csv")

    if os.environ.get("DEMO") == "1":
        items, official_ok = demo_items(now)
        status = {"demo": "ok"}
    else:
        cfg = yaml.safe_load((ROOT / "sources.yaml").read_text(encoding="utf-8"))
        items, official_ok, status = collect(cfg)

    claims = extract(items, gaz)
    events = [e for e in build_events(claims, official_ok, now)
              if datetime.fromisoformat(e["last_seen"]) > now - timedelta(hours=48)]
    feed = {"generated_at": now.isoformat(), "events": events,
            "coverage": {**COVERAGE, "power_live": bool(official_ok.get("power"))},
            "source_status": status, "labels": LABEL}
    (out / "feed.json").write_text(json.dumps(feed, ensure_ascii=False, indent=1), encoding="utf-8")
    notify(events, out)
    print(f"events={len(events)} status={status}")


if __name__ == "__main__":
    main()
