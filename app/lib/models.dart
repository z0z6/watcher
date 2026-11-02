class FeedSource {
  final String name, kind, url;
  FeedSource(this.name, this.kind, this.url);
  factory FeedSource.fromJson(Map<String, dynamic> j) =>
      FeedSource(j['name'] ?? '', j['kind'] ?? '', j['url'] ?? '');
}

class FeedEvent {
  final String id, type, place, powiat, verdict, summary, snippet;
  final int severity, credibility;
  final double lat, lon;
  final DateTime firstSeen, lastSeen;
  final bool attribution;
  final List<String> reasons;
  final List<FeedSource> sources;

  FeedEvent({
    required this.id, required this.type, required this.place, required this.powiat,
    required this.verdict, required this.summary, required this.snippet,
    required this.severity, required this.credibility, required this.lat, required this.lon,
    required this.firstSeen, required this.lastSeen, required this.attribution,
    required this.reasons, required this.sources,
  });

  factory FeedEvent.fromJson(Map<String, dynamic> j) => FeedEvent(
        id: j['id'], type: j['type'], place: j['place'], powiat: j['powiat'] ?? '',
        verdict: j['verdict'], summary: j['summary'] ?? '', snippet: j['snippet'] ?? '',
        severity: (j['severity'] as num).toInt(), credibility: (j['credibility'] as num).toInt(),
        lat: (j['lat'] as num).toDouble(), lon: (j['lon'] as num).toDouble(),
        firstSeen: DateTime.parse(j['first_seen']), lastSeen: DateTime.parse(j['last_seen']),
        attribution: j['attribution_claimed'] == true,
        reasons: List<String>.from(j['reasons'] ?? []),
        sources: ((j['sources'] ?? []) as List)
            .map((s) => FeedSource.fromJson(Map<String, dynamic>.from(s))).toList(),
      );
}

class Feed {
  final DateTime generatedAt;
  final List<FeedEvent> events;
  final Map<String, dynamic> coverage;
  Feed(this.generatedAt, this.events, this.coverage);

  factory Feed.fromJson(Map<String, dynamic> j) => Feed(
        DateTime.parse(j['generated_at']),
        ((j['events'] ?? []) as List)
            .map((e) => FeedEvent.fromJson(Map<String, dynamic>.from(e))).toList(),
        Map<String, dynamic>.from(j['coverage'] ?? {}),
      );
}

class Pin {
  String name;
  double lat, lon, radiusKm;
  Pin(this.name, this.lat, this.lon, this.radiusKm);
  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lon': lon, 'r': radiusKm};
  factory Pin.fromJson(Map<String, dynamic> j) =>
      Pin(j['name'], (j['lat'] as num).toDouble(), (j['lon'] as num).toDouble(),
          (j['r'] as num).toDouble());
}

const allTypes = ['power', 'water', 'unrest', 'shortage', 'sabotage', 'other'];
const typeLabels = {
  'power': 'Prąd', 'water': 'Woda', 'unrest': 'Niepokoje',
  'shortage': 'Braki w sklepach', 'sabotage': 'Sabotaż', 'other': 'Inne',
};
const verdictLabels = {
  'confirmed': 'Potwierdzone', 'likely': 'Prawdopodobne',
  'unverified': 'Niepotwierdzone', 'dubious': 'Podejrzane',
};

class Settings {
  int minSeverity;       // minimalna ważność zdarzenia
  double nearbyKm;       // promień wokół Twojej bieżącej lokalizacji
  double safeKm;         // powyżej: "jesteś z dala od zdarzenia"
  bool showDubious;      // pokazuj zdarzenia podejrzane (z flagą)
  int notifySeverity;    // od jakiej ważności wysyłać powiadomienia
  Set<String> types;
  String feedUrl;
  List<Pin> pins;

  Settings({
    this.minSeverity = 2, this.nearbyKm = 40, this.safeKm = 80, this.showDubious = true,
    this.notifySeverity = 4, Set<String>? types, this.feedUrl = '', List<Pin>? pins,
  })  : types = types ?? allTypes.toSet(),
        pins = pins ?? [];

  Map<String, dynamic> toJson() => {
        'minSeverity': minSeverity, 'nearbyKm': nearbyKm, 'safeKm': safeKm,
        'showDubious': showDubious, 'notifySeverity': notifySeverity,
        'types': types.toList(), 'feedUrl': feedUrl, 'pins': pins.map((p) => p.toJson()).toList(),
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        minSeverity: j['minSeverity'] ?? 2,
        nearbyKm: (j['nearbyKm'] ?? 40).toDouble(),
        safeKm: (j['safeKm'] ?? 80).toDouble(),
        showDubious: j['showDubious'] ?? true,
        notifySeverity: j['notifySeverity'] ?? 4,
        types: Set<String>.from(j['types'] ?? allTypes),
        feedUrl: j['feedUrl'] ?? '',
        pins: ((j['pins'] ?? []) as List).map((p) => Pin.fromJson(Map<String, dynamic>.from(p))).toList(),
      );
}
