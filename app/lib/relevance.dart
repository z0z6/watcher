import 'dart:math';
import 'geo.dart';
import 'models.dart';

/// Dopasowanie zdarzenia do Ciebie: bliskość bieżącej lokalizacji LUB punktów (dom, praca).
/// Punkty działają niezależnie od tego, gdzie jesteś. Zdarzenia obszarowe (powiat, województwo,
/// cały kraj) liczą się, gdy ich obszar sięga do Twojej lokalizacji lub punktu.
class Relevance {
  final FeedEvent event;
  final double? kmMe;
  final Pin? pin;
  final double? kmPin;
  final bool nearMe;
  Relevance(this.event, this.kmMe, this.pin, this.kmPin, this.nearMe);

  bool get relevant => nearMe || pin != null;

  String get proximity {
    final area = event.radiusKm > 0;
    final parts = <String>[];
    if (nearMe && kmMe != null) {
      parts.add(area && kmMe! <= event.radiusKm
          ? 'obejmuje Twoją lokalizację'
          : '${kmMe!.round()} km od Ciebie');
    }
    if (pin != null) {
      parts.add(area && kmPin! <= event.radiusKm
          ? 'obejmuje: ${pin!.name}'
          : '${kmPin!.round()} km od: ${pin!.name}');
    }
    if (parts.isEmpty && kmMe != null) parts.add('${kmMe!.round()} km od Ciebie');
    return parts.join(' · ');
  }

  /// Dodatkowa informacja kontekstowa.
  String? zoneNote(double safeKm) {
    if (kmMe == null) return null;
    if (pin != null && !nearMe && kmMe! >= safeKm) return 'Jesteś z dala od miejsca zdarzenia';
    if (nearMe) return 'Niedaleko Twojej aktualnej lokalizacji';
    return null;
  }
}

/// Filtr bez lokalizacji: ważność, typ, podejrzane. Używany przez listę i mapę.
List<FeedEvent> filterEvents(List<FeedEvent> events, Settings s) => events
    .where((e) =>
        e.severity >= s.minSeverity && s.allows(e.type) && (s.showDubious || e.verdict != 'dubious'))
    .toList();

Relevance relevanceFor(FeedEvent e, Settings s, LatLon? me) {
  final kmMe = me == null ? null : haversineKm(me.lat, me.lon, e.lat, e.lon);
  final nearMe = kmMe != null && max(0.0, kmMe - e.radiusKm) <= s.nearbyKm;
  Pin? best;
  double? bestKm;
  for (final p in s.pins) {
    final km = haversineKm(p.lat, p.lon, e.lat, e.lon);
    if (max(0.0, km - e.radiusKm) <= p.radiusKm && (bestKm == null || km < bestKm)) {
      best = p;
      bestKm = km;
    }
  }
  return Relevance(e, kmMe, best, bestKm, nearMe);
}

List<Relevance> evaluate(List<FeedEvent> events, Settings s, LatLon? me) {
  final out = filterEvents(events, s).map((e) => relevanceFor(e, s, me)).where((r) => r.relevant).toList();
  out.sort((a, b) {
    final c = b.event.severity.compareTo(a.event.severity);
    if (c != 0) return c;
    return (a.kmMe ?? a.kmPin ?? 1e9).compareTo(b.kmMe ?? b.kmPin ?? 1e9);
  });
  return out;
}
