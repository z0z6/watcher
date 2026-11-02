#!/usr/bin/env python3
"""Buduje backend/data/powiaty.csv: kod TERYT powiatu, nazwa, województwo, środek, promień (km).

Kody TERYT: Dz.U. 2025 poz. 1721 (załącznik). Granice: github.com/ppatrzyk/polska-geojson.
Uruchom raz (wymaga: pip install shapely requests). Zmień REGION, żeby zmienić obszar.
"""
import csv, json, math, sys
from pathlib import Path
import requests
from shapely.geometry import shape

GEOJSON = "https://raw.githubusercontent.com/ppatrzyk/polska-geojson/master/powiaty/powiaty-medium.geojson"

# (kod, nazwa w GeoJSON bez "powiat ", województwo)
MAZ = [("1401","białobrzeski"),("1402","ciechanowski"),("1403","garwoliński"),("1404","gostyniński"),
 ("1405","grodziski"),("1406","grójecki"),("1407","kozienicki"),("1408","legionowski"),("1409","lipski"),
 ("1410","łosicki"),("1411","makowski"),("1412","miński"),("1413","mławski"),("1414","nowodworski"),
 ("1415","ostrołęcki"),("1416","ostrowski"),("1417","otwocki"),("1418","piaseczyński"),("1419","płocki"),
 ("1420","płoński"),("1421","pruszkowski"),("1422","przasnyski"),("1423","przysuski"),("1424","pułtuski"),
 ("1425","radomski"),("1426","siedlecki"),("1427","sierpecki"),("1428","sochaczewski"),("1429","sokołowski"),
 ("1430","szydłowiecki"),("1432","warszawski zachodni"),("1433","węgrowski"),("1434","wołomiński"),
 ("1435","wyszkowski"),("1436","zwoleński"),("1437","żuromiński"),("1438","żyrardowski"),
 ("1461","Ostrołęka"),("1462","Płock"),("1463","Radom"),("1464","Siedlce"),("1465","Warszawa")]
POD = [("2001","augustowski"),("2002","białostocki"),("2003","bielski"),("2004","grajewski"),("2005","hajnowski"),
 ("2006","kolneński"),("2007","łomżyński"),("2008","moniecki"),("2009","sejneński"),("2010","siemiatycki"),
 ("2011","sokólski"),("2012","suwalski"),("2013","wysokomazowiecki"),("2014","zambrowski"),
 ("2061","Białystok"),("2062","Łomża"),("2063","Suwałki")]
WAM = [("2801","bartoszycki"),("2802","braniewski"),("2803","działdowski"),("2804","elbląski"),("2805","ełcki"),
 ("2806","giżycki"),("2818","gołdapski"),("2807","iławski"),("2808","kętrzyński"),("2809","lidzbarski"),
 ("2810","mrągowski"),("2811","nidzicki"),("2812","nowomiejski"),("2813","olecki"),("2814","olsztyński"),
 ("2815","ostródzki"),("2816","piski"),("2817","szczycieński"),("2819","węgorzewski"),
 ("2861","Elbląg"),("2862","Olsztyn")]
WOJ = {"14": ("mazowieckie", MAZ, (51.0, 53.7, 19.2, 23.3)),
       "20": ("podlaskie", POD, (52.2, 54.5, 21.8, 24.3)),
       "28": ("warmińsko-mazurskie", WAM, (53.0, 54.5, 19.0, 22.9))}

# Obszar monitorowania: północne Mazowsze, zachodnie Podlasie, południe Warmii i Mazur
REGION = {"1402","1411","1413","1415","1416","1419","1420","1422","1424","1427","1435","1437","1461","1462",
          "2003","2004","2006","2007","2008","2010","2013","2014","2062",
          "2803","2807","2810","2811","2812","2814","2815","2816","2817","2862"}

def main(out: Path):
    feats = requests.get(GEOJSON, timeout=60).json()["features"]
    rows = []
    for prefix, (woj, lst, (la0, la1, lo0, lo1)) in WOJ.items():
        for code, name in lst:
            if code not in REGION:
                continue
            cands = [f for f in feats if f["properties"]["nazwa"] == f"powiat {name}"]
            ok = []
            for f in cands:
                g = shape(f["geometry"]); c = g.centroid
                if la0 <= c.y <= la1 and lo0 <= c.x <= lo1:
                    ok.append((g, c))
            if len(ok) != 1:
                sys.exit(f"{code} {name}: znaleziono {len(ok)} dopasowań (kandydatów {len(cands)})")
            g, c = ok[0]
            area_km2 = g.area * 111.32 * 111.32 * math.cos(math.radians(c.y))
            label = f"powiat {name}" if name[0].islower() else f"m. {name}"
            rows.append((code, label, woj, round(c.y, 4), round(c.x, 4), round(math.sqrt(area_km2 / math.pi), 1)))
    with open(out, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f); w.writerow(["teryt", "name", "woj", "lat", "lon", "radius_km"]); w.writerows(rows)
    print(f"zapisano {len(rows)} powiatów -> {out}")

if __name__ == "__main__":
    main(Path(__file__).resolve().parent.parent / "backend" / "data" / "powiaty.csv")
