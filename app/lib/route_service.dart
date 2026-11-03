import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'routing.dart';

/// Trasy z publicznego serwera FOSSGIS (OSRM, dane OSM). Zasady: rozsądne, niekomercyjne użycie, maks. 1 zapytanie
/// na sekundę, poprawny User-Agent, widoczne źródło i link "popraw mapę" (obsługuje je panel trasy w aplikacji).
/// UWAGA: współrzędne punktu startu i celu są wysyłane do tego serwera.
class RouteService {
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<RouteResult> fetch(RouteMode m, double lat1, double lon1, double lat2, double lon2) async {
    final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(_last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _last = DateTime.now();
    http.Response r;
    try {
      r = await http
          .get(routeUri(m, lat1, lon1, lat2, lon2), headers: {'User-Agent': 'WatchPL/0.5 (osobista aplikacja Android)'})
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw const RouteException('Usługa tras nie odpowiada. Spróbuj ponownie za chwilę.');
    } catch (_) {
      throw const RouteException('Brak połączenia z usługą tras (potrzebny internet).');
    }
    if (r.statusCode == 429) throw const RouteException('Zbyt wiele zapytań do usługi tras - poczekaj chwilę.');
    if (r.statusCode != 200 && r.statusCode != 400) {
      throw RouteException('Usługa tras jest niedostępna (HTTP ${r.statusCode}).');
    }
    return parseOsrm(m, utf8.decode(r.bodyBytes)); // 400 zawiera JSON z kodem błędu (np. NoRoute)
  }
}
