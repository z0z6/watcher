from __future__ import annotations
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from time import mktime
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

import requests

from .geo import WOJ_PLACES, Gazetteer, Powiaty, norm
from .models import Claim, RawItem

UA = {"User-Agent": "watchpl/0.2 (personal monitor)"}
WAW = ZoneInfo("Europe/Warsaw")
REGION_WOJ = set(WOJ_PLACES)
WOJ_FALLBACK = {"podlaskie", "warminsko-mazurskie"}   # całe województwo w obszarze monitorowania


# ---------- pomocnicze ----------

def _dt(v) -> datetime | None:
    """Tolerancyjny parser dat (IMGW: 'RRRR-MM-DD GG:MM:SS' w czasie polskim, bez strefy)."""
    if not v:
        return None
    try:
        d = datetime.fromisoformat(str(v).strip().replace(" ", "T").replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=WAW)


def _first(d: dict, *keys):
    for k in keys:
        if d.get(k) not in (None, ""):
            return d[k]
    return None


def _int(v, default=1) -> int:
    try:
        return int(float(str(v).strip()))
    except (TypeError, ValueError):
        return default


def _codes(v) -> list[str]:
    if isinstance(v, (list, tuple)):
        return [str(x) for x in v]
    return [x for x in re.split(r"[,;\s]+", str(v or "")) if x]


# ---------- IMGW: ostrzeżenia (dane strukturalne, oficjalne) ----------

IMGW_SEVERITY = {1: 2, 2: 4, 3: 5}   # stopień IMGW -> ważność w aplikacji


def _imgw_item(sid, name, text, now) -> RawItem:
    return RawItem(sid, name, "official", "https://meteo.imgw.pl/", text[:300], now)


def parse_imgw_meteo(data: list[dict], powiaty: Powiaty, now: datetime) -> list[Claim]:
    claims = []
    for w in data if isinstance(data, list) else []:
        level = _int(_first(w, "stopien", "stopień"))
        event = str(_first(w, "nazwa_zdarzenia") or "Ostrzeżenie meteorologiczne")
        v_from, v_to = _dt(w.get("obowiazuje_od")), _dt(w.get("obowiazuje_do"))
        if v_to and v_to < now:
            continue
        text = str(w.get("tresc") or event)
        for code in _codes(w.get("teryt")):
            p = powiaty.get(code)
            if not p:          # powiat poza monitorowanym obszarem
                continue
            claims.append(Claim(
                _imgw_item("imgw_meteo", "IMGW-PIB ostrzeżenia meteo", text, now), p, "weather",
                IMGW_SEVERITY.get(level, 2), label=f"{event}, stopień {level}",
                key=f"imgw:{code}:{event}:{v_from:%Y%m%d%H}" if v_from else f"imgw:{code}:{event}",
                valid_to=v_to))
    return claims


def parse_imgw_hydro(data: list[dict], gaz: Gazetteer, now: datetime) -> list[Claim]:
    """Schemat ostrzeżeń hydro jest tylko częściowo znany (obszary: województwo, opis, kod zlewni),
    więc parser jest zachowawczy: miejscowość z opisu, a gdy jej brak - obszar województwa."""
    claims = []
    for w in data if isinstance(data, list) else []:
        level = _int(_first(w, "stopien", "stopień"))
        event = str(_first(w, "zdarzenie", "nazwa_zdarzenia", "nazwa") or "Ostrzeżenie hydrologiczne")
        v_from, v_to = _dt(w.get("obowiazuje_od")), _dt(w.get("obowiazuje_do"))
        if v_to and v_to < now:
            continue
        for a in w.get("obszary") or []:
            woj = norm(str(a.get("wojewodztwo", "")))
            if woj not in REGION_WOJ:
                continue
            opis = str(a.get("opis") or event)
            p = gaz.find_in_text(opis) or (WOJ_PLACES[woj] if woj in WOJ_FALLBACK else None)
            if p is None:      # mazowieckie: tylko gdy opis wskazuje znaną miejscowość (reszta poza obszarem)
                continue
            claims.append(Claim(
                _imgw_item("imgw_hydro", "IMGW-PIB ostrzeżenia hydro", opis, now), p, "disaster",
                IMGW_SEVERITY.get(level, 2), label=f"{event}, stopień {level}",
                key=f"imgwh:{woj}:{p.name}:{event}:{v_from:%Y%m%d%H}" if v_from else f"imgwh:{woj}:{event}",
                valid_to=v_to))
    return claims


def fetch_imgw_meteo(src, gaz, powiaty, now) -> list[Claim]:
    r = requests.get(src["url"], headers=UA, timeout=25)
    r.raise_for_status()
    return parse_imgw_meteo(r.json(), powiaty, now)


def fetch_imgw_hydro(src, gaz, powiaty, now) -> list[Claim]:
    r = requests.get(src["url"], headers=UA, timeout=25)
    r.raise_for_status()
    return parse_imgw_hydro(r.json(), gaz, now)


# ---------- wiadomości: Google News RSS (jeden adapter dla wielu lokalnych mediów) ----------

def _clean(html: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html or "")).strip()


def fetch_google_news(src, gaz: Gazetteer, now) -> list[RawItem]:
    import feedparser
    topics = src.get("topics", "prąd OR woda OR pożar OR wichura OR zamieszki OR awaria")
    when = src.get("when", "2d")
    trusted = set(src.get("trusted_domains", []))
    queries = [f'"{p.name}" ({topics}) when:{when}' for p in gaz.query_places]
    queries += [f"{q} when:{when}" for q in src.get("region_queries", []) + src.get("national_queries", [])]
    items, seen = [], set()
    for i, q in enumerate(queries):
        url = "https://news.google.com/rss/search?" + urlencode(
            {"q": q, "hl": "pl", "gl": "PL", "ceid": "PL:pl"})
        d = feedparser.parse(url, request_headers=UA)
        if i == 0 and not d.entries and d.get("bozo") and d.get("status", 200) >= 400:
            raise RuntimeError(f"Google News HTTP {d.get('status')}")
        for e in d.entries[:12]:
            link = e.get("link", "")
            if link in seen:
                continue
            seen.add(link)
            domain = (e.get("source") or {}).get("href", "").replace("https://", "").replace("http://", "").strip("/")
            publisher = (e.get("source") or {}).get("title", "") or domain or "Google News"
            title = re.sub(r"\s+-\s+[^-]+$", "", e.get("title", ""))
            ts = e.get("published_parsed")
            pub = datetime.fromtimestamp(mktime(ts), timezone.utc) if ts else now
            kind = "media_national" if any(domain.endswith(t) for t in trusted) else "media_local"
            items.append(RawItem(domain or publisher, publisher, kind, link,
                                 f"{title}. {_clean(e.get('summary', ''))}", pub))
        time.sleep(0.7)   # grzeczność wobec serwera
    return items


# ---------- RSS i XML operatora ----------

def fetch_rss(src, gaz, now) -> list[RawItem]:
    import feedparser
    d = feedparser.parse(src["url"], request_headers=UA)
    out = []
    for e in d.entries[:60]:
        ts = e.get("published_parsed") or e.get("updated_parsed")
        pub = datetime.fromtimestamp(mktime(ts), timezone.utc) if ts else now
        out.append(RawItem(src["id"], src["name"], src["kind"], e.get("link", src["url"]),
                           f"{e.get('title', '')}. {_clean(e.get('summary', ''))}", pub))
    return out


def fetch_xml_records(src, gaz, now) -> list[RawItem]:
    """Tolerancyjny parser: każdy rekord (dziecko korzenia) -> jeden RawItem ze spłaszczonym tekstem.
    Schemat XML operatora nie jest zweryfikowany, więc nie zakładamy nazw pól."""
    r = requests.get(src["url"], headers=UA, timeout=20)
    r.raise_for_status()
    root = ET.fromstring(r.content)
    out = []
    for rec in list(root):
        text = " ".join(t.strip() for t in rec.itertext() if t.strip())
        if text:
            out.append(RawItem(src["id"], src["name"], src["kind"], src["url"], text, now))
    return out


ITEM_FETCHERS = {"rss": fetch_rss, "xml_records": fetch_xml_records, "google_news": fetch_google_news}
CLAIM_FETCHERS = {"imgw_meteo": fetch_imgw_meteo, "imgw_hydro": fetch_imgw_hydro}


def collect(cfg: dict, gaz: Gazetteer, powiaty: Powiaty, now: datetime):
    items: list[RawItem] = []
    claims: list[Claim] = []
    official_ok: dict[str, bool] = {}
    status: dict[str, str] = {}
    for src in cfg.get("sources", []):
        sid = src["id"]
        needs_url = src["type"] != "google_news"
        if not src.get("enabled", True) or (needs_url and not src.get("url")):
            status[sid] = "wyłączone"
            continue
        try:
            if src["type"] in CLAIM_FETCHERS:
                got = CLAIM_FETCHERS[src["type"]](src, gaz, powiaty, now)
                claims += got
            else:
                got = ITEM_FETCHERS[src["type"]](src, gaz, now)
                items += got
            status[sid] = f"ok ({len(got)})"
            for t in src.get("hard_types", []):
                official_ok[t] = True
        except Exception as e:  # noqa: BLE001
            status[sid] = f"błąd: {type(e).__name__}"
            print(f"[sources] {sid}: {e}", file=sys.stderr)
    return items, claims, official_ok, status
