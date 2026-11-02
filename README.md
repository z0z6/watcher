# WatchPL

Prywatny monitor zdarzeń dla północnego Mazowsza, zachodniego Podlasia i południa Warmii i Mazur.
Backend ocenia **wiarygodność** doniesień twardymi sygnałami, aplikacja (Flutter, styl iOS) pokazuje na liście
i **mapie** tylko to, co spełnia Twoje kryteria.

**Typy zdarzeń:** prąd, woda, pogoda (wichury, mrozy, upały, burze), klęski żywiołowe (pożary, powodzie),
infrastruktura (banki, urzędy, łączność), epidemie, niepokoje, braki w sklepach, sabotaż.

## Jak to działa
```
GH Actions (cron co 10 min)           Aplikacja Android
 IMGW (ostrzeżenia, strukturalne)      pobiera feed.json
 + wiadomości (Google News RSS)        filtruje LOKALNIE: GPS + punkty (dom, praca)
 -> ekstrakcja (LLM lub reguły)        lista + mapa (OpenStreetMap)
 -> klastrowanie -> scoring            powiadomienia lokalne (WorkManager, ~15 min)
 -> feed.json (gałąź data)  ------->
 -> opcjonalnie push ntfy
```
**Prywatność:** feed jest wspólny dla regionu, a Twoja lokalizacja i punkty nigdy nie opuszczają telefonu.

## Źródła
| Źródło | Rodzaj | Status |
|---|---|---|
| IMGW-PIB ostrzeżenia meteo (`/api/data/warningsmeteo`) | oficjalne, strukturalne, powiaty (TERYT) | pola potwierdzone w dokumentacji stron trzecich; **nietestowane na żywo** |
| IMGW-PIB ostrzeżenia hydro (`/api/data/warningshydro`) | oficjalne, obszary (województwo + opis) | schemat tylko częściowo znany - parser zachowawczy |
| Google News RSS | wiadomości lokalne i krajowe, jeden adapter | **nietestowane na żywo**; Google może limitować zapytania z GH Actions |
| Energa / PGE (wyłączenia prądu) | oficjalne, twarde dane o prądzie | wyłączone - brak zweryfikowanych endpointów |

**Pierwszy krok po wdrożeniu:** *Actions -> feed -> Run workflow* z `probe = 1`. Wypisze, co zwraca każde źródło
(liczba rekordów, przykłady) i pokaże, czy parsery pasują do prawdziwych danych.

Zdarzenia z IMGW są obszarowe (powiat): na mapie widać zasięg kółkiem. Zdarzenia ogólnokrajowe (awaria mObywatela)
trafiają na listę, ale nie na mapę.

## Wdrożenie
1. Wrzuć repo na GitHub (publiczne, jeśli chcesz czytać feed przez raw.githubusercontent.com).
2. *Settings -> Secrets and variables -> Actions*: `ANTHROPIC_API_KEY` (opcjonalnie; bez niego ekstrakcja
   regułowa, mniej dokładna dla wiadomości), `NTFY_PREFIX` (opcjonalnie).
3. *Actions -> feed -> Run workflow*: najpierw `probe = 1`, potem `demo = 1` (dane demonstracyjne).
4. *Actions -> build-apk*, pobierz `watchpl-apk`, zainstaluj.
5. W aplikacji (Ustawienia): `https://raw.githubusercontent.com/<user>/<repo>/data/feed.json`.
6. Zakładka Miejsca: dodaj dom i pracę.

## Dane obszaru
`backend/data/powiaty.csv` (33 powiaty, kody TERYT z Dz.U. 2025 poz. 1721, środki z granic powiatów)
generuje `tools/build_powiaty.py`. Zmień `REGION` w skrypcie, żeby zmienić obszar. `backend/data/places.csv`
(18 miast) służy do rozpoznawania miejscowości w tekstach - rozbuduj o kolejne.

## Ograniczenia
- Testy: backend (15 testów) przechodzi; **aplikacja Flutter nie była kompilowana w środowisku, w którym powstała**.
- Powiadomienia w tle: min. 15 min, mogą być opóźnione przez oszczędzanie baterii. Alerty wokół Ciebie w tle
  wymagają lokalizacji "Zawsze"; alerty o punktach działają bez niej.
- Ostrzeżenia hydro bez rozpoznanej miejscowości dostają obszar całego województwa (promień 60 km od środka).
- Mapa używa publicznych kafelków OpenStreetMap - OK do osobistego użytku, nie do dużego ruchu.
- Brak alertu != spokój: infrastruktura, epidemie, niepokoje i sklepy mają słabe pokrycie danych (aplikacja to pokazuje).
- Wagi źródeł (`models.py`) i progi werdyktów (`score.py`) to heurystyki startowe - dostrajaj je.
