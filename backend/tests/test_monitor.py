from datetime import datetime, timedelta, timezone
from pathlib import Path

from monitor.demo import demo_items
from monitor.extract import rule_extract
from monitor.geo import Gazetteer, haversine_km
from monitor.models import RawItem
from monitor.score import build_events

GAZ = Gazetteer.load(Path(__file__).resolve().parent.parent / "data" / "places.csv")
NOW = datetime(2026, 11, 2, 12, 0, tzinfo=timezone.utc)


def item(sid, kind, text, minutes_ago=120):
    return RawItem(sid, sid, kind, "https://x.invalid", text, NOW - timedelta(minutes=minutes_ago))


def test_gazetteer_declension():
    assert GAZ.find_in_text("w Ostrołęce nie ma prądu").name == "Ostrołęka"
    assert GAZ.find_in_text("awaria w Ostródzie").name == "Ostróda"
    assert GAZ.find_in_text("w Mławie ciemno").name == "Mława"
    assert GAZ.find_in_text("Wysokiem Mazowieckiem brak wody").name == "Wysokie Mazowieckie"
    assert GAZ.find_in_text("nic tu nie ma") is None


def test_rule_extract_sabotage_attribution():
    c = rule_extract(item("a", "social", "W Płońsku brak prądu, to chyba sabotaż"), GAZ)[0]
    assert c.type == "power" and c.attribution_claimed and c.place.name == "Płońsk"


def test_unconfirmed_blackout_is_capped_and_flagged():
    cl = rule_extract(item("tg", "social", "W Przasnyszu brak prądu, sabotaż"), GAZ)
    ev = build_events(cl, {"power": True}, NOW)[0]
    assert ev["credibility"] <= 35 and ev["verdict"] == "dubious"
    assert any("operatora" in r for r in ev["reasons"])
    assert any("sabotażu" in r for r in ev["reasons"])


def test_fresh_event_not_capped():
    cl = rule_extract(item("tg", "social", "W Przasnyszu brak prądu", 5), GAZ)
    ev = build_events(cl, {"power": True}, NOW)[0]
    assert any("świeże" in r for r in ev["reasons"])


def test_official_confirms():
    cl = (rule_extract(item("tg", "social", "W Ostrołęce brak prądu"), GAZ)
          + rule_extract(item("energa", "official", "Ostrołęka wyłączenie awaryjne brak prądu"), GAZ))
    ev = build_events(cl, {"power": True}, NOW)[0]
    assert ev["verdict"] == "confirmed" and ev["credibility"] >= 90


def test_copied_text_counts_as_one_origin():
    txt = "W Przasnyszu nigdzie nie ma prądu całe miasto bez zasilania"
    cl = sum((rule_extract(item(s, "social", txt), GAZ) for s in ("a", "b", "c")), [])
    ev = build_events(cl, {}, NOW)[0]
    assert ev["reasons"][0] == "Tylko 1 niezależne źródło"
    assert any("Ten sam tekst" in r for r in ev["reasons"])


def test_demo_pipeline():
    items, ok = demo_items(NOW)
    claims = [c for it in items for c in rule_extract(it, GAZ)]
    ev = {e["place"]: e for e in build_events(claims, ok, NOW)}
    assert ev["Przasnysz"]["verdict"] == "dubious"
    assert ev["Działdowo"]["verdict"] == "confirmed"
    assert ev["Ostrołęka"]["verdict"] == "confirmed"
    assert ev["Olsztyn"]["verdict"] in ("unverified", "likely")


def test_haversine():
    assert 65 < haversine_km(52.8817, 20.6193, 53.0840, 21.5740) < 71  # ok. 68 km
