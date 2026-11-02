import 'geo.dart';
import 'models.dart';

/// Wynik dopasowania zdarzenia do Ciebie: bliskość bieżącej lokalizacji LUB punktów (dom, praca).
/// Punkty działają niezależnie od tego, gdzie aktualnie jesteś.
class Relevance {
  final FeedEvent event;
  final double? kmMe;
  final Pin? pin;
  final double? kmPin;
  final bool nearMe;
  Relevance(this.event, this.kmMe, this.pin, this.kmPin, this.nearMe);

  String get proximity {
    final parts = <String>[];
    if (nearMe && kmMe != null) parts.add('${kmMe!.round()} km od Ciebie');
    if (pin != null) parts.add('${kmPin!.round()} km od: ${pin!.name}');
    if (parts.isEmpty && kmMe != null) parts.add('${kmMe!.round()} km od Ciebie');
    return parts.join(' · ');
  }

  /// Dodatkowa informacja kontekstowa, gdy zdarzenie dotyczy punktu, a Ty jesteś gdzie indziej.
  String? zoneNote(double safeKm) {
    if (kmMe == null) return null;
    if (pin != null && !nearMe && kmMe! >= safeKm) return 'Jesteś z dala od miejsca zdarzenia';
    if (nearMe) return 'Niedaleko Twojej aktualnej lokalizacji';
    return null;
  }
}

List<Relevance> evaluate(List<FeedEvent> events, Settings s, LatLon? me) {
  final out = <Relevance>[];
  for (final e in events) {
    if (e.severity < s.minSeverity) continue;
    if (!s.types.contains(e.type)) continue;
    if (!s.showDubious && e.verdict == 'dubious') continue;

    final kmMe = me == null ? null : haversineKm(me.lat, me.lon, e.lat, e.lon);
    final nearMe = kmMe != null && kmMe <= s.nearbyKm;

    Pin? best;
    double? bestKm;
    for (final p in s.pins) {
      final km = haversineKm(p.lat, p.lon, e.lat, e.lon);
      if (km <= p.radiusKm && (bestKm == null || km < bestKm)) {
        best = p;
        bestKm = km;
      }
    }
    if (!nearMe && best == null) continue;
    out.add(Relevance(e, kmMe, best, bestKm, nearMe));
  }
  out.sort((a, b) {
    final c = b.event.severity.compareTo(a.event.severity);
    if (c != 0) return c;
    return (a.kmMe ?? a.kmPin ?? 1e9).compareTo(b.kmMe ?? b.kmPin ?? 1e9);
  });
  return out;
}
