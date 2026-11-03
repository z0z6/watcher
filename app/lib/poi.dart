import 'dart:convert';

import 'geo.dart';

/// Obiekty o znaczeniu strategicznym w kryzysie (dane OSM z backendu: backend/monitor/poi.py).
class PoiCategory {
  final String id, label, emoji;
  final int minZoom; // poniżej tego przybliżenia kategoria jest ukryta (żeby mapa była czytelna)
  const PoiCategory(this.id, this.label, this.emoji, this.minZoom);
}

const poiCategories = [
  PoiCategory('pharmacy', 'Apteki', '💊', 11),
  PoiCategory('fuel', 'Paliwo', '⛽', 11),
  PoiCategory('hospital', 'Szpitale', '🏥', 8),
  PoiCategory('school', 'Szkoły', '🏫', 12),
  PoiCategory('bridge', 'Mosty', '🌉', 11),
  PoiCategory('military', 'Wojsko', '🎖️', 8),
];

PoiCategory poiCategory(String id) => poiCategories.firstWhere((c) => c.id == id);

const poiDisclaimer = 'Dane obiektów: OpenStreetMap (ODbL), tworzone przez społeczność - mogą być niepełne lub nieaktualne '
    '(zwłaszcza mosty i obiekty wojskowe). Sprawdź na miejscu; w razie zagrożenia stosuj się do komunikatów służb (112).';

class Poi {
  final String cat, name, extra;
  final double lat, lon;
  const Poi(this.cat, this.name, this.extra, this.lat, this.lon);
}

class PoiSet {
  final String fetchedAt, license;
  final bool demo;
  final Map<String, List<Poi>> byCat;
  const PoiSet(this.fetchedAt, this.license, this.demo, this.byCat);

  int count(String cat) => byCat[cat]?.length ?? 0;

  /// Zapis kolumnowy z backendu: {"cats": {"pharmacy": {"lat": [...], "lon": [...], "name": [...], "x": [...]}}}.
  factory PoiSet.fromJson(Map<String, dynamic> j) {
    final out = <String, List<Poi>>{};
    (j['cats'] as Map<String, dynamic>).forEach((id, v) {
      final m = v as Map<String, dynamic>;
      final lat = (m['lat'] as List).map((e) => (e as num).toDouble()).toList();
      final lon = (m['lon'] as List).map((e) => (e as num).toDouble()).toList();
      final name = (m['name'] as List).cast<String>();
      final x = (m['x'] as List).cast<String>();
      if ([lon.length, name.length, x.length].any((n) => n != lat.length)) {
        throw FormatException('poi.json ($id): kolumny mają różne długości');
      }
      out[id] = [for (var i = 0; i < lat.length; i++) Poi(id, name[i], x[i], lat[i], lon[i])];
    });
    return PoiSet((j['fetched_at'] ?? '') as String, (j['license'] ?? '') as String, j['demo'] == true, out);
  }

  /// Obiekty kategorii w widocznym prostokącie. Gdy jest ich więcej niż limit, zostają najbliższe środka widoku.
  List<Poi> inBounds(String cat, double south, double west, double north, double east, {int limit = 120}) {
    final all = byCat[cat];
    if (all == null) return const [];
    final out = [for (final p in all) if (p.lat >= south && p.lat <= north && p.lon >= west && p.lon <= east) p];
    if (out.length <= limit) return out;
    final cLat = (south + north) / 2, cLon = (west + east) / 2;
    out.sort((a, b) => haversineKm(cLat, cLon, a.lat, a.lon).compareTo(haversineKm(cLat, cLon, b.lat, b.lon)));
    return out.sublist(0, limit);
  }
}

PoiSet parsePoi(String body) => PoiSet.fromJson(jsonDecode(body) as Map<String, dynamic>);
