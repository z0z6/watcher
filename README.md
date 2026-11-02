# WatchPL

Prywatny monitor zdarzeń (prąd, woda, niepokoje, braki w sklepach, sabotaż) dla północnego Mazowsza,
zachodniego Podlasia i południa Warmii i Mazur. Backend ocenia **wiarygodność** doniesień twardymi sygnałami,
aplikacja (Flutter, styl iOS) pokazuje tylko to, co spełnia Twoje kryteria.

## Jak to działa
```
GH Actions (cron co 10 min)           Aplikacja Android
 źródła -> ekstrakcja (LLM/reguły)     pobiera feed.json
 -> klastrowanie -> scoring            filtruje LOKALNIE: GPS + punkty (dom, praca)
 -> feed.json (gałąź data)  ------->   powiadomienia lokalne (WorkManager, ~15 min)
 -> opcjonalnie push ntfy
```
**Prywatność:** feed jest wspólny dla całego regionu, a Twoja lokalizacja i punkty nigdy nie opuszczają telefonu.

## Wdrożenie
1. Wrzuć repo na GitHub (publiczne, jeśli chcesz czytać feed przez raw.githubusercontent.com).
2. *Settings -> Secrets and variables -> Actions*: `ANTHROPIC_API_KEY` (opcjonalnie; bez niego działa ekstrakcja regułowa),
   `NTFY_PREFIX` (opcjonalnie, losowy ciąg - prefiks tematów ntfy).
3. *Actions -> feed -> Run workflow* z `demo = 1`, żeby zobaczyć działający feed na danych demonstracyjnych.
4. *Actions -> build-apk -> Run workflow*, pobierz artefakt `watchpl-apk`, zainstaluj.
5. W aplikacji (Ustawienia) wklej: `https://raw.githubusercontent.com/<user>/<repo>/data/feed.json`.
6. Zakładka Miejsca: dodaj dom i pracę.

## Co jest zweryfikowane, a co nie
- Backend: testy jednostkowe przechodzą (`cd backend && python -m pytest`), pipeline działa na danych demo.
- **Aplikacja Flutter nie była kompilowana** w środowisku, w którym powstała. Pierwszy build w Actions może
  wymagać drobnych poprawek (wersje wtyczek, gradle) - wklej log błędu.
- **Źródła:** adresy w `backend/sources.yaml` oznaczone "DO SPRAWDZENIA" są niezweryfikowane i wyłączone.
  Włączaj po sprawdzeniu endpointów i regulaminów.
- `backend/data/places.csv` to mały zestaw startowy (18 miast). Docelowo zastąp go pełnym rejestrem TERYT/PRG.

## Znane ograniczenia
- Powiadomienia w tle: min. 15 min, mogą być opóźnione przez oszczędzanie baterii. Alerty wokół Ciebie w tle
  wymagają lokalizacji "Zawsze"; alerty o punktach działają bez niej.
- Brak alertu != spokój: braki w sklepach i zamieszki mają słabe pokrycie danych (aplikacja to pokazuje).
- Wagi źródeł (`models.py`) i progi werdyktów (`score.py`) to heurystyki startowe - dostrajaj je.
