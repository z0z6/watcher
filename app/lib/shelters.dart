import 'dart:convert';
import 'dart:math';

import 'geo.dart';

/// Kolejność jak w backendzie (backend/monitor/shelters.py): 3 = nieznana wartość w pliku PSP.
const availabilityLabels = ['Całodobowa', 'Określone godziny', 'Na żądanie', 'Brak danych'];

const shelterDisclaimer = 'Punkt na mapie nie gwarantuje schronienia ani dostępu o każdej porze - sprawdź na miejscu. '
    'To nie jest oficjalna aplikacja PSP (oficjalny serwis: gdziesieukryc.pl). W razie zagrożenia stosuj się '
    'do komunikatów służb i dzwoń 112. Brak punktu w okolicy nie oznacza, że nie ma żadnego miejsca ukrycia.';

/// Trasa piesza do punktu w Mapach Google.
String walkLink(double lat, double lon) =>
    'https://www.google.com/maps/dir/?api=1&destination=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}&travelmode=walking';

class Shelter {
  final String id, adres, gmina, type;
  final double lat, lon;
  final int d; // 0 całodobowa, 1 określone godziny, 2 na żądanie, 3 brak danych
  const Shelter(this.id, this.lat, this.lon, this.adres, this.gmina, this.d, [this.type = '']);
}

class ShelterHit {
  final Shelter s;
  final double km;
  const ShelterHit(this.s, this.km);

  /// Czas dojścia w linii prostej, ok. 5 km/h.
  int get walkMinutes => max(1, (km * 12).round());

  String get distanceLabel => km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';
}

class ShelterSet {
  final String stan, license;
  final bool demo;
  final List<Shelter> items;
  const ShelterSet(this.stan, this.license, this.demo, this.items);

  String get stanPl {
    final p = stan.split('-');
    return p.length == 3 ? '${p[2]}.${p[1]}.${p[0]}' : stan;
  }

  /// Zapis kolumnowy z backendu: {"id": [...], "lat": [...], "lon": [...], "adres": [...], "gmina": [...], "d": [...]}.
  factory ShelterSet.fromJson(Map<String, dynamic> j) {
    final ids = (j['id'] as List).cast<String>();
    final lat = (j['lat'] as List).map((e) => (e as num).toDouble()).toList();
    final lon = (j['lon'] as List).map((e) => (e as num).toDouble()).toList();
    final adres = (j['adres'] as List).cast<String>();
    final gmina = (j['gmina'] as List).cast<String>();
    final d = (j['d'] as List).map((e) => (e as num).toInt()).toList();
    final t = j['t'] == null ? null : (j['t'] as List).cast<String>();
    final n = ids.length;
    if ([lat.length, lon.length, adres.length, gmina.length, d.length].any((x) => x != n)) {
      throw const FormatException('shelters.json: kolumny mają różne długości');
    }
    return ShelterSet(
      (j['stan'] ?? '') as String,
      (j['license'] ?? '') as String,
      j['demo'] == true,
      [for (var i = 0; i < n; i++) Shelter(ids[i], lat[i], lon[i], adres[i], gmina[i], d[i].clamp(0, 3), t == null ? '' : t[i])],
    );
  }

  /// Najbliższe punkty w promieniu radiusKm od (lat, lon), od najbliższego.
  List<ShelterHit> nearest(double lat, double lon, double radiusKm, {int limit = 100}) {
    final dLat = radiusKm / 111.0;
    final dLon = radiusKm / (111.0 * cos(lat * pi / 180));
    final out = <ShelterHit>[];
    for (final s in items) {
      if ((s.lat - lat).abs() > dLat || (s.lon - lon).abs() > dLon) continue;
      final km = haversineKm(lat, lon, s.lat, s.lon);
      if (km <= radiusKm) out.add(ShelterHit(s, km));
    }
    out.sort((a, b) => a.km.compareTo(b.km));
    return out.length > limit ? out.sublist(0, limit) : out;
  }
}

/// Funkcja najwyższego poziomu, żeby można ją było uruchomić w compute() (osobny wątek).
ShelterSet parseShelters(String body) => ShelterSet.fromJson(jsonDecode(body) as Map<String, dynamic>);
