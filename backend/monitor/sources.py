from __future__ import annotations
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from time import mktime

import requests

from .models import RawItem

UA = {"User-Agent": "watchpl/0.1 (personal monitor)"}


def fetch_rss(src: dict) -> list[RawItem]:
    import feedparser
    d = feedparser.parse(src["url"], request_headers=UA)
    out = []
    for e in d.entries[:60]:
        ts = e.get("published_parsed") or e.get("updated_parsed")
        pub = datetime.fromtimestamp(mktime(ts), timezone.utc) if ts else datetime.now(timezone.utc)
        text = f"{e.get('title', '')}. {e.get('summary', '')}"
        out.append(RawItem(src["id"], src["name"], src["kind"], e.get("link", src["url"]), text, pub))
    return out


def fetch_xml_records(src: dict) -> list[RawItem]:
    """Tolerancyjny parser: każdy rekord (dziecko korzenia) -> jeden RawItem ze spłaszczonym tekstem.
    Schemat XML operatora nie jest zweryfikowany, więc nie zakładamy nazw pól."""
    r = requests.get(src["url"], headers=UA, timeout=20)
    r.raise_for_status()
    root = ET.fromstring(r.content)
    now = datetime.now(timezone.utc)
    out = []
    for rec in list(root):
        text = " ".join(t.strip() for t in rec.itertext() if t.strip())
        if text:
            out.append(RawItem(src["id"], src["name"], src["kind"], src["url"], text, now))
    return out


FETCHERS = {"rss": fetch_rss, "xml_records": fetch_xml_records}


def collect(cfg: dict) -> tuple[list[RawItem], dict[str, bool], dict[str, str]]:
    items: list[RawItem] = []
    official_ok: dict[str, bool] = {}
    status: dict[str, str] = {}
    for src in cfg.get("sources", []):
        if not src.get("enabled", True) or not src.get("url"):
            status[src["id"]] = "wyłączone"
            continue
        try:
            got = FETCHERS[src["type"]](src)
            items += got
            status[src["id"]] = f"ok ({len(got)})"
            for t in src.get("hard_types", []):
                official_ok[t] = True
        except Exception as e:  # noqa: BLE001
            status[src["id"]] = f"błąd: {type(e).__name__}"
            print(f"[sources] {src['id']}: {e}", file=sys.stderr)
    return items, official_ok, status
