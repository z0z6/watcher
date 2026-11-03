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

## Pogoda
Pogoda pochodzi **wyłącznie z ostrzeżeń IMGW** (oficjalne, z datami obowiązywania). Pogoda "z wiadomości" jest domyślnie
wyłączona (`weather_from_news: false` w `sources.yaml`), bo to głównie przedruki i dawne zdarzenia. Dodatkowo
wiadomości przechodzą kontrolę sezonowości: upał w listopadzie albo śnieg w lipcu w świeżym artykule to prawie na pewno
stara historia i jest odrzucany. Dowody z weryfikacji AI muszą mieć znaną datę strony nie starszą niż 3 dni.

## Schrony (dane rządowe)
Źródło: oficjalny zbiór Komendy Głównej PSP "Punkty schronienia w Polsce"
(https://dane.gov.pl/pl/dataset/28058,punkty-schronienia-w-polsce, plik CSV z serwisu gdziesieukryc.pl, aktualizowany w
poniedziałki, ok. 88 tys. punktów w kraju). Backend pobiera plik tylko gdy się zmienił (nagłówek Last-Modified), filtruje
do obszaru monitorowania i publikuje `shelters.json` obok `feed.json`. Aplikacja trzyma kopię w telefonie, więc **lista
schronów działa bez internetu** (kafelki mapy nie).
- Zakładka **Schrony**: najbliższe punkty wokół Ciebie, domu albo pracy (1 / 2 / 5 km), odległość, czas dojścia
  w linii prostej, dostępność (całodobowa / określone godziny / na żądanie), trasa piesza w Mapach Google.
- Mapa: przycisk tarczy włącza warstwę schronów, a pasek "Schrony: Ja / Dom / Praca" przełącza punkt odniesienia.
- Status pobierania: `source_status.shelters` w `feed.json`. Nazwy kolumn CSV pochodzą z kodu niezależnego projektu,
  który czyta ten plik, a nie z testów na żywo - przy zmianie formatu parser kończy się jawnym błędem, nie cichym brakiem.
- To **nie jest oficjalna aplikacja PSP** i punkt na mapie nie gwarantuje schronienia ani dostępu. Licencja zbioru wg
  opisu: CC BY 4.0 (źródło: KG PSP, dane.gov.pl) - sprawdź na stronie zbioru. Nowa kategoria ustawowa "punkt schronienia"
  (od 29.05.2026) to nie to samo co schron, ukrycie czy miejsce doraźnego schronienia. Rejestr CEOZO (ceozo.pl) nie jest
  zintegrowany (brak zweryfikowanego otwartego API).

## Udostępnianie
Systemowe okno udostępniania Androida (`share_plus`): Signal, SMS, e-mail, WhatsApp itd. Udostępnić można zdarzenie
(z oceną, linkiem do źródła i mapą), lokalizację zdarzenia, schron, punkt (dom/praca) i własną lokalizację. Facebook
Messenger bywa niedostępny w tym oknie (ograniczenia Meta) - użyj wtedy "Skopiuj". Treść udostępnianego zdarzenia mówi
wprost, że ocena jest automatyczna i podaje link do sprawdzenia.

## Dane obszaru
`backend/data/powiaty.csv` (57 powiatów, kody TERYT z Dz.U. 2025 poz. 1721, środki z granic powiatów)
generuje `tools/build_powiaty.py`. Zmień `REGION` w skrypcie, żeby zmienić obszar. `backend/data/places.csv`
(53 miejscowości) służy do rozpoznawania miejscowości w tekstach. Kolumna `query` = czy pytać o nią Google News
osobno, kolumna `forms` = formy odmiany dla nazw mylących (Pisz/pisze, Węgrów/Węgry). Rozbuduj o kolejne.

## Ograniczenia
- Testy: backend (35 testów), logika Darta (modele, schrony, teksty udostępniania) sprawdzona kompilatorem Darta i testem zgodności z plikami backendu; pliki z interfejsem Fluttera przeszły tylko kontrolę składni przechodzi; **aplikacja Flutter nie była kompilowana w środowisku, w którym powstała**.
- Powiadomienia w tle: min. 15 min, mogą być opóźnione przez oszczędzanie baterii. Alerty wokół Ciebie w tle
  wymagają lokalizacji "Zawsze"; alerty o punktach działają bez niej.
- Ostrzeżenia hydro bez rozpoznanej miejscowości dostają obszar całego województwa (promień 60 km od środka).
- Mapa używa publicznych kafelków OpenStreetMap - OK do osobistego użytku, nie do dużego ruchu.
- Brak alertu != spokój: infrastruktura, epidemie, niepokoje i sklepy mają słabe pokrycie danych (aplikacja to pokazuje).
- Wagi źródeł (`models.py`) i progi werdyktów (`score.py`) to heurystyki startowe - dostrajaj je.
