# WatchPL

Prywatny monitor zdarzeń dla **północno-wschodniej Polski**: całe podlaskie i warmińsko-mazurskie oraz
północna i wschodnia część mazowieckiego (57 powiatów).
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

## Mapa i wygląd
- Jasny i ciemny motyw (Ustawienia -> Wygląd: Auto / Jasny / Ciemny). Mapa używa kafelków OpenStreetMap (bez klucza); ciemny motyw to ten sam kafelek przefiltrowany kolorystycznie.
  (CARTO wymaga teraz klucza API, więc z niego zrezygnowałem.)
- Punkty zdarzeń pulsują powoli, tym szybciej, im wyższa ważność: czerwony (4-5), żółty (3), szary (1-2).
  Podejrzane są szare, bez pulsu.
- Okienko ze szczegółami rozwija się po **najechaniu** (mysz, rysik) lub **dotknięciu** punktu.
- NOWE zdarzenie: szybki pierścień "ping" wokół punktu, baner od góry z wibracją, znacznik "● NOWE" na liście
  (10 min), licznik w pastylce LIVE. Aplikacja odświeża dane sama co 3 minuty, gdy jest otwarta.
- Wygląd odwzorowuje konwencje paneli OSINT (ciemne tło, kolory ostrzegawcze, pulsujące punkty), a nie
  konkretną stronę - nie widziałem jej wyglądu, tylko opis i dokumentację projektu open source.

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
5. Adres feedu jest wpisany na stałe w `app/lib/models.dart` (`defaultFeedUrl`) - zmień go na własne repozytorium
   przed budowaniem. Można go też nadpisać w Ustawienia -> Źródło danych. Najpierw otwórz ten adres w przeglądarce telefonu - ma pokazać JSON. Repozytorium musi być publiczne.
6. Zakładka Miejsca: dodaj dom i pracę.

## Świeżość i weryfikacja (agent AI)
1. **Twarda świeżość** (`max_age_hours` w `sources.yaml`, domyślnie 36 h): pozycje starsze albo bez daty odpadają
   przed analizą. Wcześniej pozycja bez daty była traktowana jak świeża.
2. **Wykrywanie dawnych zdarzeń w treści**: przedruki i odświeżone artykuły mają świeżą datę, ale opisują stare
   wydarzenia ("pół roku temu", "w 2024 roku", "12 marca...", "rocznica"). Takie pozycje są odrzucane regułami,
   a model dostaje datę publikacji i dzisiejszą datę oraz zwraca `current` i `event_date`.
3. **Weryfikacja wyszukiwarką** (wymaga `ANTHROPIC_API_KEY`): dla ważnych (>= 3/5), niepotwierdzonych zdarzeń
   model szuka niezależnych, aktualnych potwierdzeń. Akceptowane są **tylko adresy URL, które faktycznie wystąpiły
   w wynikach wyszukiwania** (model nie może wymyślić linku). Wynik jest zapamiętywany w `state.json`, więc to samo
   zdarzenie kosztuje jedno wyszukiwanie; limit `VERIFY_MAX` (domyślnie 3) nowych na uruchomienie.
   Wyłączenie: zmienna `VERIFY=0`. Oficjalnie potwierdzone zdarzenia nigdy nie są obniżane.
4. **Linki do źródeł**: każde zdarzenie ma listę źródeł z tytułem, datą i adresem artykułu/komunikatu. W aplikacji
   dotknięcie źródła (w szczegółach lub w rozwijanej karcie na mapie) otwiera oryginał w przeglądarce.
   Linki z Google News przechodzą przez przekierowanie Google do strony wydawcy.

## Dane obszaru
`backend/data/powiaty.csv` (57 powiatów, kody TERYT z Dz.U. 2025 poz. 1721, środki z granic powiatów)
generuje `tools/build_powiaty.py`. Zmień `REGION` w skrypcie, żeby zmienić obszar. `backend/data/places.csv`
(53 miejscowości) służy do rozpoznawania miejscowości w tekstach. Kolumna `query` = czy pytać o nią Google News
osobno, kolumna `forms` = formy odmiany dla nazw mylących (Pisz/pisze, Węgrów/Węgry). Rozbuduj o kolejne.

## Ograniczenia
- Testy: backend (25 testów) przechodzi; **aplikacja Flutter nie była kompilowana w środowisku, w którym powstała**.
- Powiadomienia w tle: min. 15 min, mogą być opóźnione przez oszczędzanie baterii. Alerty wokół Ciebie w tle
  wymagają lokalizacji "Zawsze"; alerty o punktach działają bez niej.
- Ostrzeżenia hydro bez rozpoznanej miejscowości dostają obszar całego województwa (promień 60 km od środka).
- Mapa używa publicznych kafelków OpenStreetMap - OK do osobistego użytku, nie do dużego ruchu.
- Brak alertu != spokój: infrastruktura, epidemie, niepokoje i sklepy mają słabe pokrycie danych (aplikacja to pokazuje).
- Wagi źródeł (`models.py`) i progi werdyktów (`score.py`) to heurystyki startowe - dostrajaj je.
