import 'dart:convert';
import 'dart:math';

import 'geo.dart';

/// Tryby trasy. Ścieżki routed-foot / routed-bike / routed-car to układ serwerów FOSSGIS
/// (routing.openstreetmap.de); sam serwer demonstracyjny OSRM zawsze liczy trasę samochodową.
enum RouteMode {
  foot('Pieszo', '🚶', 'routed-foot', 'walking'),
  bike('Rowerem', '🚲', 'routed-bike', 'bicycling'),
  car('Autem', '🚗', 'routed-car', 'driving');

  final String label, emoji, path, google;
  const RouteMode(this.label, this.emoji, this.path, this.google);
}

Uri routeUri(RouteMode m, double lat1, double lon1, double lat2, double lon2) => Uri.parse(
    'https://routing.openstreetmap.de/${m.path}/route/v1/driving/'
    '${lon1.toStringAsFixed(6)},${lat1.toStringAsFixed(6)};${lon2.toStringAsFixed(6)},${lat2.toStringAsFixed(6)}'
    '?overview=full&geometries=geojson');

/// Ta sama trasa w Mapach Google (nawigacja głosowa itd.).
String googleRouteLink(RouteMode m, double lat1, double lon1, double lat2, double lon2) =>
    'https://www.google.com/maps/dir/?api=1&origin=${lat1.toStringAsFixed(6)},${lon1.toStringAsFixed(6)}'
    '&destination=${lat2.toStringAsFixed(6)},${lon2.toStringAsFixed(6)}&travelmode=${m.google}';

const osmFixTheMapUrl = 'https://www.openstreetmap.org/fixthemap';

class RouteException implements Exception {
  final String message;
  const RouteException(this.message);
  @override
  String toString() => message;
}

class RouteResult {
  final RouteMode mode;
  final List<LatLon> points;
  final double km, minutes;
  const RouteResult(this.mode, this.points, this.km, this.minutes);
}

RouteResult parseOsrm(RouteMode mode, String body) {
  final Map<String, dynamic> j;
  try {
    j = jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    throw const RouteException('Usługa tras zwróciła nieczytelną odpowiedź.');
  }
  final code = j['code'];
  if (code != 'Ok') {
    throw RouteException(code == 'NoRoute' || code == 'NoSegment'
        ? 'Brak trasy między tymi punktami (np. punkt poza siecią dróg lub ścieżek).'
        : 'Usługa tras zwróciła błąd: $code');
  }
  final routes = j['routes'] as List?;
  if (routes == null || routes.isEmpty) throw const RouteException('Brak trasy między tymi punktami.');
  final r = routes.first as Map<String, dynamic>;
  final coords = ((r['geometry'] as Map<String, dynamic>)['coordinates'] as List)
      .map((c) => LatLon((c[1] as num).toDouble(), (c[0] as num).toDouble()))
      .toList();
  return RouteResult(mode, coords, (r['distance'] as num).toDouble() / 1000, (r['duration'] as num).toDouble() / 60);
}

String fmtDist(double km) => km < 1
    ? '${(km * 1000).round()} m'
    : '${km.toStringAsFixed(km < 10 ? 2 : 1).replaceAll('.', ',')} km';

String fmtDur(double minutes) {
  if (minutes < 1) return '< 1 min';
  final m = minutes.round();
  return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}

/// Azymut początkowy z punktu 1 do punktu 2 (0-360, 0 = północ).
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * pi / 180;
  final dl = rad(lon2 - lon1);
  final y = sin(dl) * cos(rad(lat2));
  final x = cos(rad(lat1)) * sin(rad(lat2)) - sin(rad(lat1)) * cos(rad(lat2)) * cos(dl);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

String bearingLabel(double deg) {
  const names = [
    'północ', 'północny wschód', 'wschód', 'południowy wschód',
    'południe', 'południowy zachód', 'zachód', 'północny zachód',
  ];
  return names[((deg + 22.5) % 360 ~/ 45)];
}
