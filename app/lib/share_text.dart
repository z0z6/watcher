import 'models.dart';
import 'poi.dart';
import 'routing.dart';
import 'shelters.dart';

/// Teksty do udostępniania (Signal, Messenger, SMS, e-mail...). Czyste funkcje, bez zależności od Fluttera.

String mapsLink(double lat, double lon) =>
    'https://www.google.com/maps?q=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

String _fmt(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}.${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
}

/// Opis zdarzenia z oceną wiarygodności i linkiem do źródła, żeby odbiorca mógł sam sprawdzić.
/// Ocena jest automatyczna - wiadomość mówi to wprost, żeby niepotwierdzone doniesienia
/// nie wyglądały na fakty.
String eventText(FeedEvent e, {String? proximity}) {
  final src = e.sources.where((s) => s.openable).cast<FeedSource?>().firstWhere((_) => true, orElse: () => null);
  final b = StringBuffer()
    ..writeln('⚠️ ${e.summary}')
    ..writeln('${typeLabels[e.type] ?? e.type} · ważność ${e.severity}/5 · '
        '${verdictLabels[e.verdict] ?? e.verdict} (${e.credibility}%)');
  if (proximity != null && proximity.isNotEmpty) b.writeln(proximity);
  if (!e.nationwide) {
    b.writeln('📍 ${e.place}');
    b.writeln(mapsLink(e.lat, e.lon));
  }
  if (e.validTo != null) b.writeln('Obowiązuje do: ${_fmt(e.validTo!)}');
  if (src != null) {
    b.writeln('🔗 Źródło (${src.name}): ${src.url}');
    b.writeln('Sprawdź sam, otwierając link.');
  }
  b.write('— WatchPL, dane z ${_fmt(e.lastSeen)}. Ocena automatyczna, może zawierać błędy.');
  return b.toString();
}

String locationText(String label, double lat, double lon) =>
    '📍 $label\n${mapsLink(lat, lon)}\n(${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})';

String shelterText(Shelter s, {double? km}) {
  final b = StringBuffer()
    ..writeln('🛡️ Punkt schronienia: ${s.adres.isEmpty ? s.gmina : s.adres}')
    ..writeln('${s.gmina} · dostępność: ${availabilityLabels[s.d]}${km == null ? '' : ' · ${km.toStringAsFixed(2)} km'}')
    ..writeln(mapsLink(s.lat, s.lon))
    ..writeln('Trasa piesza: ${walkLink(s.lat, s.lon)}')
    ..write('Źródło: Komenda Główna PSP, dane.gov.pl. Sprawdź dostępność na miejscu.');
  return b.toString();
}

String poiText(Poi p, PoiCategory c) {
  final b = StringBuffer()
    ..writeln('${c.emoji} ${p.name}')
    ..writeln('${c.label}${p.extra.isEmpty ? '' : ' · ${p.extra}'}')
    ..writeln(mapsLink(p.lat, p.lon))
    ..write('Dane: OpenStreetMap. Mogą być nieaktualne - sprawdź na miejscu.');
  return b.toString();
}

/// Pomiar odległości i (opcjonalnie) trasa między dwoma punktami.
String measureText(String aLabel, String bLabel, double aLat, double aLon, double bLat, double bLon, double km,
    {RouteResult? route}) {
  final b = StringBuffer()
    ..writeln('📏 $aLabel → $bLabel')
    ..writeln('W linii prostej: ${fmtDist(km)}, kierunek: ${bearingLabel(bearingDeg(aLat, aLon, bLat, bLon))}');
  if (route != null) {
    b
      ..writeln('${route.mode.emoji} ${route.mode.label}: ${fmtDist(route.km)}, ok. ${fmtDur(route.minutes)}')
      ..writeln(googleRouteLink(route.mode, aLat, aLon, bLat, bLon));
  }
  b
    ..writeln('A: ${mapsLink(aLat, aLon)}')
    ..write('B: ${mapsLink(bLat, bLon)}');
  return b.toString();
}
