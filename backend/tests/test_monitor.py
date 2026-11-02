from datetime import datetime, timedelta, timezone
from pathlib import Path

from monitor.demo import demo_items
from monitor.extract import rule_extract
from monitor.geo import NATIONAL, Gazetteer, Powiaty, haversine_km
from monitor.models import RawItem
from monitor.score import build_events
from monitor.sources import parse_imgw_hydro, parse_imgw_meteo

DATA = Path(__file__).resolve().parent.parent / "data"
GAZ = Gazetteer.load(DATA / "places.csv")
POW = Powiaty(DATA / "powiaty.csv")
NOW = datetime(2026, 11, 2, 12, 0, tzinfo=timezone.utc)


def item(sid, kind, text, minutes_ago=120):
    return RawItem(sid, sid, kind, "https://x.invalid", text, NOW - timedelta(minutes=minutes_ago))


def one(text, kind="media_local", minutes_ago=120):
    return rule_extract(item("s", kind, text, minutes_ago), GAZ)


# ---------- geo ----------

def test_gazetteer_declension():
    assert GAZ.find_in_text("w Ostrołęce nie ma prądu").name == "Ostrołęka"
    assert GAZ.find_in_text("awaria w Ostródzie").name == "Ostróda"
    assert GAZ.find_in_text("w Mławie ciemno").name == "Mława"
    assert GAZ.find_in_text("Wysokiem Mazowieckiem brak wody").name == "Wysokie Mazowieckie"
    assert GAZ.find_in_text("nic tu nie ma") is None


def test_gazetteer_no_false_positives():
    for text in ("Płonie las pod miastem", "Pisze do nas czytelnik z gminy", "Premier spotkał się z Węgrami w Budapeszcie",
                 "Ostro skrytykował rząd", "Biskup odprawił mszę", "Morał z tej historii jest prosty"):
        assert GAZ.find_in_text(text) is None, text
    assert GAZ.find_in_text("Pożar w Płońsku").name == "Płońsk"
    assert GAZ.find_in_text("Awaria w Piszu").name == "Pisz"
    assert GAZ.find_in_text("w Węgrowie nie ma wody").name == "Węgrów"
    assert GAZ.find_in_text("Ełk: burza przeszła nad miastem").name == "Ełk"


def test_gazetteer_covers_whole_ne_poland():
    for text, name in (("Wichura w Suwałkach", "Suwałki"), ("Brak prądu w Giżycku", "Giżycko"),
                       ("Awaria w Hajnówce", "Hajnówka"), ("Pożar w Elblągu", "Elbląg"),
                       ("Zalane ulice w Białymstoku", "Białystok"), ("Burza w Siedlcach", "Siedlce")):
        assert GAZ.find_in_text(text).name == name, text
    assert len(GAZ.query_places) < len(GAZ.places)    # nie odpytujemy wiadomości o każdą wieś


def test_powiaty_by_teryt():
    assert POW.get("1402").name == "powiat ciechanowski"
    assert POW.get(1413).powiat == "mławski"
    assert POW.get("1402000").name == "powiat ciechanowski"   # kod z końcówką też działa
    assert POW.get("140201").name == "powiat ciechanowski"    # kod gminy -> powiat
    assert POW.get("0201") is None                            # poza obszarem
    assert 10 < POW.get("2814").radius_km < 40
    assert POW.get("2012").name == "powiat suwalski"          # podlaskie w całości
    assert POW.get("2805").name == "powiat ełcki"             # warmińsko-mazurskie w całości
    assert len(POW.by_code) >= 50


def test_haversine():
    assert 65 < haversine_km(52.8817, 20.6193, 53.0840, 21.5740) < 71  # Ciechanów-Ostrołęka ~ 68 km


# ---------- nowe typy zdarzeń (reguły) ----------

def test_types_weather_disaster_infra_epidemic():
    assert one("Silna wichura w Ciechanowie, połamane drzewa")[0].type == "weather"
    assert one("Pożar lasu pod Łomżą, trwa ewakuacja")[0].type == "disaster"
    assert one("Powódź w Pułtusku, wylała rzeka")[0].type == "disaster"
    assert one("W Olsztynie awaria bankomatów i systemu bankowego")[0].type == "infrastructure"
    assert one("Sanepid: ognisko salmonelli w Działdowie")[0].type == "epidemic"


def test_nationwide_infra_goes_to_national():
    c = one("Awaria mObywatela w całej Polsce, urzędy nie działają")[0]
    assert c.place is NATIONAL and c.type == "infrastructure"


def test_irrelevant_text_ignored():
    assert one("Ciechanów: nowy sklep otwarty w centrum") == []
    assert one("Mecz w Olsztynie zakończony remisem") == []


def test_severity_escalates():
    low = one("Burza w Płońsku")[0].severity
    high = one("Nawałnica w Płońsku, alarm trzeciego stopnia")[0].severity
    assert high > low


# ---------- IMGW ----------

IMGW_METEO = [
    {"nazwa_zdarzenia": "Silny wiatr", "stopien": "2", "prawdopodobienstwo": "80",
     "obowiazuje_od": "2026-11-02 10:00:00", "obowiazuje_do": "2026-11-03 06:00:00",
     "tresc": "Prognozuje się wiatr do 80 km/h.", "biuro": "IMGW Warszawa",
     "teryt": ["1402", "1413", "0201"]},
    {"nazwa_zdarzenia": "Mróz", "stopien": 1, "obowiazuje_od": "2026-11-01 10:00:00",
     "obowiazuje_do": "2026-11-02 08:00:00", "tresc": "stare", "teryt": "1402"},   # wygasłe
]


def test_imgw_meteo_parsing():
    cl = parse_imgw_meteo(IMGW_METEO, POW, NOW)
    assert sorted(c.place.name for c in cl) == ["powiat ciechanowski", "powiat mławski"]  # 0201 odfiltrowane, wygasłe pominięte
    assert all(c.type == "weather" and c.severity == 4 for c in cl)
    assert cl[0].label.startswith("Silny wiatr")


def test_imgw_events_confirmed_and_stable_id():
    ev = build_events(parse_imgw_meteo(IMGW_METEO, POW, NOW), {}, NOW)
    assert all(e["verdict"] == "confirmed" and e["radius_km"] > 0 for e in ev)
    later = build_events(parse_imgw_meteo(IMGW_METEO, POW, NOW + timedelta(minutes=30)), {}, NOW + timedelta(minutes=30))
    assert {e["id"] for e in ev} == {e["id"] for e in later}   # id stabilne między uruchomieniami


def test_imgw_hydro_place_from_text_or_voivodeship():
    data = [{"zdarzenie": "Wezbranie wody", "stopien": 2, "obowiazuje_od": "2026-11-02 08:00:00",
             "obowiazuje_do": "2026-11-04 08:00:00",
             "obszary": [{"wojewodztwo": "warmińsko-mazurskie", "opis": "Rzeka Drwęca w rejonie Nidzicy"},
                         {"wojewodztwo": "podlaskie", "opis": "Narew"},
                         {"wojewodztwo": "małopolskie", "opis": "Wisła"},
                         {"wojewodztwo": "mazowieckie", "opis": "Wisła w Warszawie"}]}]
    cl = parse_imgw_hydro(data, GAZ, NOW)
    assert sorted(c.place.name for c in cl) == ["Nidzica", "woj. podlaskie"]
    assert all(c.type == "disaster" for c in cl)


# ---------- ocena wiarygodności ----------

def test_unconfirmed_blackout_is_capped_and_flagged():
    ev = build_events(one("W Przasnyszu brak prądu, sabotaż", "social"), {"power": True}, NOW)[0]
    assert ev["credibility"] <= 35 and ev["verdict"] == "dubious"
    assert any("operatora" in r for r in ev["reasons"])
    assert any("sabotażu" in r for r in ev["reasons"])


def test_fresh_event_not_capped():
    ev = build_events(one("W Przasnyszu brak prądu", "social", 5), {"power": True}, NOW)[0]
    assert any("świeże" in r for r in ev["reasons"])


def test_official_confirms():
    cl = one("W Ostrołęce brak prądu", "social") + one("Ostrołęka wyłączenie awaryjne brak prądu", "official")
    ev = build_events(cl, {"power": True}, NOW)[0]
    assert ev["verdict"] == "confirmed" and ev["credibility"] >= 90


def test_copied_text_counts_as_one_origin():
    txt = "W Przasnyszu nigdzie nie ma prądu całe miasto bez zasilania"
    cl = sum((rule_extract(item(s, "social", txt), GAZ) for s in ("a", "b", "c")), [])
    ev = build_events(cl, {}, NOW)[0]
    assert ev["reasons"][0] == "Tylko 1 niezależne źródło"
    assert any("Ten sam tekst" in r for r in ev["reasons"])


def test_demo_pipeline():
    items, claims, ok = demo_items(NOW, POW)
    claims = claims + [c for it in items for c in rule_extract(it, GAZ)]
    ev = build_events(claims, ok, NOW)
    by = {(e["place"], e["type"]): e for e in ev}
    assert by[("Przasnysz", "power")]["verdict"] == "dubious"
    assert by[("Działdowo", "water")]["verdict"] == "confirmed"
    assert by[("Ostrołęka", "power")]["verdict"] == "confirmed"
    assert by[("Łomża", "disaster")]["verdict"] == "unverified"   # 1 źródło krajowe = 70% < 75%
    assert by[("Cała Polska", "infrastructure")]["radius_km"] == 400
    assert by[("powiat mławski", "weather")]["severity"] == 5
