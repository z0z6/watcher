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


# ---------- świeżość i dawne zdarzenia ----------
from types import SimpleNamespace as NS

from monitor.extract import looks_historical
from monitor.run import fresh_items
from monitor.verify import apply_record, ask, verify_events


def test_historical_text_detected():
    ref = NOW
    for t in ("Pół roku temu w Ciechanowie wybuchł pożar hali", "W 2024 roku w Olsztynie doszło do awarii prądu",
              "Rocznica powodzi w Łomży", "Pożar w Suwałkach 12 marca strawił magazyn",
              "Wspominamy wichurę, która przeszła nad Mławą w zeszłym roku"):
        assert looks_historical(t, ref), t
    for t in ("Brak prądu w Ciechanowie od godziny", "Od 5 listopada obowiązuje ostrzeżenie przed wiatrem",
              "Pożar hali w Suwałkach, trwa akcja gaśnicza"):
        assert not looks_historical(t, ref), t


def test_rule_extract_skips_old_stories_even_with_fresh_date():
    assert one("Pożar lasu pod Łomżą - przypominamy, 12 marca spłonęło 30 hektarów") == []
    assert one("Pożar lasu pod Łomżą, trwa akcja gaśnicza")[0].type == "disaster"


def test_fresh_items_drops_old_and_undated():
    from monitor.sources import UNKNOWN_DATE
    keep = item("a", "media_local", "x", 60)
    old = item("b", "media_local", "x", 60 * 24 * 180)         # pół roku temu
    undated = RawItem("c", "c", "media_local", "https://x", "x", UNKNOWN_DATE)
    assert fresh_items([keep, old, undated], NOW, 36) == [keep]


def test_events_carry_source_links_best_first():
    cl = (rule_extract(RawItem("tg", "Kanał", "social", "https://t.me/x/1", "W Ostrołęce brak prądu", NOW - timedelta(minutes=50),
                               "Brak prądu"), GAZ)
          + rule_extract(RawItem("pap", "PAP", "media_national", "https://pap.pl/a", "W Ostrołęce nie ma prądu w centrum",
                                 NOW - timedelta(minutes=40), "Ostrołęka bez prądu"), GAZ))
    ev = build_events(cl, {}, NOW)[0]
    assert [s["url"] for s in ev["sources"]] == ["https://pap.pl/a", "https://t.me/x/1"]   # wiarygodniejsze pierwsze
    assert ev["sources"][0]["title"] == "Ostrołęka bez prądu" and "published" in ev["sources"][0]


# ---------- weryfikacja wyszukiwarką ----------

def fake_client(answer_json, result_urls, page_age="1 day ago"):
    resp = NS(content=[
        NS(type="web_search_tool_result", content=[NS(url=u, title="t " + u, page_age=page_age) for u in result_urls]),
        NS(type="text", text="Wynik:\n" + answer_json),
    ])
    return NS(messages=NS(create=lambda **kw: resp))


def base_event():
    cl = one("W Przasnyszu brak prądu", "media_local", 300)
    return build_events(cl, {}, NOW)[0]


def test_verify_drops_hallucinated_urls_and_known_domains():
    e = base_event()
    ans = ('{"current": true, "corroborated": true, "note": "ok", "evidence": ['
           '{"url": "https://prawdziwy.pl/a", "title": "A"}, {"url": "https://wymyslony.pl/b", "title": "B"},'
           '{"url": "https://x.invalid/dup", "title": "dup"}]}')
    client = fake_client(ans, ["https://prawdziwy.pl/a", "https://x.invalid/dup"])
    rec = ask(client, "m", e, NOW)
    assert [x["url"] for x in rec["evidence"]] == ["https://prawdziwy.pl/a"]   # wymyślony odpadł, x.invalid już jest źródłem... 
    assert rec["corroborated"]


def test_verify_raises_credibility_and_adds_links():
    e = base_event()
    before = e["credibility"]
    apply_record(e, {"current": True, "corroborated": True, "note": "", "at": NOW.isoformat(),
                     "evidence": [{"url": "https://lokalny.pl/a", "title": "A"}, {"url": "https://inny.pl/b", "title": "B"}]})
    assert e["credibility"] > before
    assert {s["url"] for s in e["sources"]} >= {"https://lokalny.pl/a", "https://inny.pl/b"}
    assert any("Weryfikacja AI" in r for r in e["reasons"])


def test_verify_not_current_marks_dubious_but_never_touches_confirmed():
    e = base_event()
    apply_record(e, {"current": False, "corroborated": False, "evidence": []})
    assert e["verdict"] == "dubious" and e["credibility"] <= 30
    conf = build_events(one("Ostrołęka wyłączenie awaryjne brak prądu", "official"), {}, NOW)[0]
    apply_record(conf, {"current": False, "corroborated": False, "evidence": []})
    assert conf["verdict"] == "confirmed"


def test_verify_events_caches_and_respects_limit(monkeypatch):
    monkeypatch.setenv("VERIFY_MAX", "1")
    calls = []

    def create(**kw):
        calls.append(1)
        return NS(content=[NS(type="text", text='{"current": true, "corroborated": false, "evidence": [], "note": ""}')])

    client = NS(messages=NS(create=create))
    e1 = build_events(one("W Przasnyszu brak prądu", "media_local", 300), {}, NOW)[0]
    e2 = build_events(one("W Płońsku wichura, połamane drzewa", "media_local", 300), {}, NOW)[0]
    state = {}
    assert verify_events([e1, e2], state, NOW, client) == 1 and len(calls) == 1      # limit 1 na uruchomienie
    e1b = build_events(one("W Przasnyszu brak prądu", "media_local", 300), {}, NOW)[0]
    e2b = build_events(one("W Płońsku wichura, połamane drzewa", "media_local", 300), {}, NOW)[0]
    assert verify_events([e1b, e2b], state, NOW, client) == 1 and len(calls) == 2    # wcześniejszy z cache, drugi nowy
    assert verify_events([e1b, e2b], state, NOW, client) == 0 and len(calls) == 2    # wszystko z cache


# ---------- pogoda: sezonowość i brak pogody z wiadomości ----------
from monitor.extract import season_mismatch
from monitor.verify import parse_page_age


def test_season_mismatch_catches_stale_heat_story():
    assert season_mismatch("Upał w pociągu: pasażerowie bez klimatyzacji", NOW)        # listopad
    assert not season_mismatch("Upał w pociągu", NOW.replace(month=7))
    assert season_mismatch("Śnieg i gołoledź w Ełku", NOW.replace(month=7))
    assert not season_mismatch("Mróz w Suwałkach, -15 stopni", NOW)
    assert one("Upał w pociągu relacji Białystok - Warszawa, awaria klimatyzacji") == []


def test_weather_from_news_disabled_by_default():
    from monitor.run import drop_weather_news
    cl = one("Silna wichura w Ciechanowie, połamane drzewa") + one("Brak prądu w Mławie")
    assert [c.type for c in cl] == ["weather", "power"]
    assert [c.type for c in drop_weather_news(cl, {})] == ["power"]                       # domyślnie bez pogody z wiadomości
    assert [c.type for c in drop_weather_news(cl, {"weather_from_news": True})] == ["weather", "power"]


def test_imgw_future_warning_far_ahead_skipped():
    far = [{"nazwa_zdarzenia": "Upał", "stopien": 1, "obowiazuje_od": "2026-11-10 10:00:00",
            "obowiazuje_do": "2026-11-11 10:00:00", "teryt": ["1402"]}]
    assert parse_imgw_meteo(far, POW, NOW) == []


def test_verify_requires_fresh_known_page_age():
    e = base_event()
    ans = '{"current": true, "corroborated": true, "note": "", "evidence": [{"url": "https://stary.pl/a", "title": "A"}]}'
    assert ask(fake_client(ans, ["https://stary.pl/a"], page_age="April 30, 2025"), "m", e, NOW)["evidence"] == []
    assert ask(fake_client(ans, ["https://stary.pl/a"], page_age=""), "m", e, NOW)["evidence"] == []
    assert len(ask(fake_client(ans, ["https://stary.pl/a"], page_age="2 days ago"), "m", e, NOW)["evidence"]) == 1


def test_parse_page_age_formats():
    assert parse_page_age("3 days ago", NOW) == NOW - timedelta(days=3)
    assert parse_page_age("November 1, 2026", NOW).day == 1
    assert parse_page_age("nonsense", NOW) is None


# ---------- schrony (CSV PSP) ----------
import json as _json

from monitor import shelters as sh

BBOX = sh.region_bbox(POW)
CSV = ('\ufeff"Identyfikator publiczny","Szerokosc geograficzna","Dlugosc geograficzna","Adres","Gmina","Dostepnosc"\r\n'
       '"OZO-1","52.881700","20.619300","ul. Kościuszki 5, lok. ""A"", Ciechanów","Ciechanów","Całodobowa"\r\n'
       '"OZO-2","53,0840","21,5740","Parking podziemny, Ostrołęka","Ostrołęka","Określone godziny"\r\n'
       '"OZO-3","50.0647","19.9450","Kraków - poza obszarem","Kraków","Na żądanie"\r\n'
       '"OZO-4","","20.1","brak współrzędnej","Mława","Całodobowa"\r\n'
       '"OZO-5","54.1118","22.9309","Suwałki centrum","Suwałki","Coś nowego"\r\n')


def test_region_bbox_covers_ne_poland_only():
    la0, la1, lo0, lo1 = BBOX
    assert la0 < 52.0 and la1 > 54.3 and lo0 < 19.3 and lo1 > 24.0     # obejmuje całe NE
    assert not (la0 <= 50.0647 <= la1)                                  # Kraków poza


def test_parse_shelters_csv_bom_quotes_commas_and_filters():
    cols, st = sh.parse_csv(CSV, BBOX)
    assert cols["id"] == ["OZO-1", "OZO-2", "OZO-5"]
    assert cols["adres"][0] == 'ul. Kościuszki 5, lok. "A", Ciechanów'      # pole w cudzysłowie z przecinkiem i ""
    assert cols["lat"][1] == 53.084 and cols["lon"][1] == 21.574            # przecinek dziesiętny
    assert cols["d"] == [0, 1, 3]                                           # 3 = nieznana dostępność
    assert st == {"rows": 5, "kept": 3, "bad_coords": 1, "unknown_availability": 1}


def test_parse_shelters_missing_column_fails_loudly():
    bad = 'Id,Szerokosc geograficzna,Dlugosc geograficzna,Adres,Gmina\r\n1,52,20,x,y\r\n'
    try:
        sh.parse_csv(bad, BBOX)
    except ValueError as e:
        assert "identyfikator" in str(e) or "dostepnosc" in str(e)
    else:
        raise AssertionError("powinien rzucić ValueError")


def test_refresh_skips_download_when_unchanged_and_downloads_when_changed(tmp_path):
    calls = {"get": 0}
    lm = "Mon, 02 Nov 2026 06:00:00 GMT"

    class R:
        def __init__(self, headers=None, content=b""):
            self.headers, self.content = headers or {}, content

        def raise_for_status(self):
            pass

    class S:
        def head(self, *a, **k):
            return R({"Last-Modified": lm})

        def get(self, *a, **k):
            calls["get"] += 1
            return R({"Last-Modified": lm}, CSV.encode("utf-8"))

    msg = sh.refresh(tmp_path, NOW, POW, S())
    assert msg.startswith("ok (3 z 5") and calls["get"] == 1
    doc = _json.loads((tmp_path / "shelters.json").read_text(encoding="utf-8"))
    assert doc["stan"] == "2026-11-02" and doc["n"] == 3 and "CC BY" in doc["license"]
    assert sh.refresh(tmp_path, NOW + timedelta(hours=6), POW, S()).startswith("bez zmian") and calls["get"] == 1
    lm = "Mon, 09 Nov 2026 06:00:00 GMT"                                    # PSP zaktualizowało plik
    assert sh.refresh(tmp_path, NOW + timedelta(days=7), POW, S()).startswith("ok") and calls["get"] == 2


def test_demo_shelters_replaced_by_real_download(tmp_path):
    sh.demo_shelters(tmp_path, NOW, GAZ.places)
    assert _json.loads((tmp_path / "shelters.json").read_text(encoding="utf-8"))["demo"] is True

    class R:
        headers = {"Last-Modified": "Mon, 02 Nov 2026 06:00:00 GMT"}
        content = CSV.encode("utf-8")

        def raise_for_status(self):
            pass

    class S:
        head = staticmethod(lambda *a, **k: R())
        get = staticmethod(lambda *a, **k: R())

    assert sh.refresh(tmp_path, NOW, POW, S()).startswith("ok")
    assert "demo" not in _json.loads((tmp_path / "shelters.json").read_text(encoding="utf-8"))


# ---------- obiekty strategiczne z OSM (Overpass) ----------
from monitor import poi as poimod


def node(lat, lon, **tags):
    return {"type": "node", "id": 1, "lat": lat, "lon": lon, "tags": tags}


def way_c(lat, lon, **tags):
    return {"type": "way", "id": 2, "center": {"lat": lat, "lon": lon}, "tags": tags}


def bridge(lat, lon, dlon, **tags):
    return {"type": "way", "id": 3, "bounds": {"minlat": lat, "maxlat": lat + 0.0001, "minlon": lon, "maxlon": lon + dlon},
            "tags": {"highway": "primary", **tags}}


def test_overpass_query_restricted_to_poland_and_region_bbox():
    q = poimod.build_query("pharmacy", BBOX)
    assert 'area["ISO3166-1"="PL"][admin_level=2]->.pl' in q and "(area.pl)(" in q and q.endswith("out center tags;")
    assert poimod.build_query("bridge", BBOX).endswith("out tags bb;")
    assert '"military"~' in poimod.build_query("military", BBOX)


def test_build_category_pharmacy_fuel_hospital_military():
    ph = poimod.build_category("pharmacy", [node(52.88, 20.62, name="Apteka Zdrowie", opening_hours="24/7"),
                                           node(52.88, 20.62, name="Apteka Zdrowie"),          # duplikat
                                           way_c(53.1, 21.5, opening_hours="Mo-Fr 08:00-20:00")])
    assert ph["n"] == 2 and ph["x"][0] == "całodobowa" and ph["name"][1] == "Apteka"
    fu = poimod.build_category("fuel", [node(53.0, 21.0, brand="Orlen", opening_hours="24/7", **{"fuel:lpg": "yes"})])
    assert fu["x"][0] == "Orlen, całodobowo, LPG"
    ho = poimod.build_category("hospital", [way_c(53.78, 20.48, name="Szpital Wojewódzki", emergency="yes")])
    assert ho["x"][0] == "izba przyjęć/SOR"
    mi = poimod.build_category("military", [way_c(53.4, 20.4, military="barracks", name="JW 1234"),
                                           way_c(53.5, 20.5, office="military")])
    assert mi["x"] == ["koszary", "instytucja wojskowa"] and mi["name"][1] == "Obiekt wojskowy"


def test_bridges_filtered_by_length_or_name_and_deduped():
    short = bridge(53.0, 21.0, 0.0001, ref="DK8")                 # ~7 m: przepust
    long_ = bridge(53.1, 21.1, 0.004, ref="DK8", name="Most na Narwi")   # ~270 m
    twin = bridge(53.1, 21.1005, 0.004, ref="DK8", name="Most na Narwi")  # druga jezdnia, ~35 m obok
    unnamed_long = bridge(53.2, 21.2, 0.004, ref="S8")
    r = poimod.build_category("bridge", [short, long_, twin, unnamed_long])
    assert r["name"] == ["Most na Narwi", "Most"] and r["n"] == 2
    assert "DK8" in r["x"][0] and "droga krajowa" in r["x"][0] and "~" in r["x"][0]


def test_poi_refresh_merges_old_categories_on_partial_failure(tmp_path):
    import requests as rq

    class R:
        def __init__(self, els):
            self.status_code, self._els = 200, els

        def raise_for_status(self):
            pass

        def json(self):
            return {"elements": self._els}

    class S:
        def __init__(self, fail):
            self.fail, self.n = fail, 0

        def post(self, url, data=None, **k):
            self.n += 1
            q = data["data"]
            if self.fail and '"bridge"' in q:
                raise rq.ConnectionError("boom")
            return R([node(53.0, 21.0, name="X")] if "pharmacy" in q else [])

    msg = poimod.refresh(tmp_path, NOW, POW, S(fail=True), sleep=lambda s: None)
    assert msg.startswith("ok (") and "błędy: bridge" in msg
    doc = _json.loads((tmp_path / "poi.json").read_text(encoding="utf-8"))
    assert doc["cats"]["pharmacy"]["n"] == 1 and "bridge" not in doc["cats"] and "bridge" in doc["errors"]
    # po błędach nie ma ponownej próby przez 6 h (Overpass to wspólny zasób)...
    s_wait = S(fail=False)
    assert poimod.refresh(tmp_path, NOW + timedelta(hours=1), POW, s_wait, sleep=lambda s: None).startswith("ponowna próba po 6 h")
    assert s_wait.n == 0
    # ...potem ponowna próba uzupełnia brakującą kategorię, reszta zostaje
    s2 = S(fail=False)
    msg2 = poimod.refresh(tmp_path, NOW + timedelta(hours=7), POW, s2, sleep=lambda s: None)
    doc2 = _json.loads((tmp_path / "poi.json").read_text(encoding="utf-8"))
    assert "bridge" in doc2["cats"] and not doc2["errors"] and msg2.startswith("ok (")
    # dane kompletne i świeże -> brak zapytań
    s3 = S(fail=False)
    assert poimod.refresh(tmp_path, NOW + timedelta(days=2, hours=7), POW, s3, sleep=lambda s: None).startswith("bez zmian") and s3.n == 0


def test_poi_demo_and_run_status(tmp_path):
    assert poimod.demo_poi(tmp_path, NOW, GAZ.places).startswith("demo")
    doc = _json.loads((tmp_path / "poi.json").read_text(encoding="utf-8"))
    assert set(doc["cats"]) == set(poimod.CATEGORIES) and doc["demo"] is True
