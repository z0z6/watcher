/// Adres feedu zapisany na stałe (gałąź data tego repozytorium).
const defaultFeedUrl = 'https://raw.githubusercontent.com/z0z6/watcher/data/feed.json';

const kindLabels = {
  'official': 'oficjalne', 'media_national': 'media krajowe', 'media_local': 'media lokalne',
  'social': 'social media', 'aggregator': 'agregator', 'ai_search': 'wyszukiwarka AI',
};

class FeedSource {
  final String name, kind, url, title;
  final DateTime? published;
  FeedSource(this.name, this.kind, this.url, this.title, this.published);

  /// Link do konkretnego artykułu/komunikatu, który można otworzyć i sprawdzić samemu.
  bool get openable {
    final u = Uri.tryParse(url);
    return u != null && (u.scheme == 'https' || u.scheme == 'http') && !u.host.endsWith('.invalid');
  }

  factory FeedSource.fromJson(Map<String, dynamic> j) => FeedSource(
        j['name'] ?? '', j['kind'] ?? '', j['url'] ?? '', j['title'] ?? '',
        j['published'] == null ? null : DateTime.tryParse(j['published']),
      );
}

class FeedEvent {
  final String id, type, place, powiat, verdict, summary, snippet;
  final int severity, credibility;
  final double lat, lon, radiusKm;   // radiusKm > 0: zdarzenie obszarowe (powiat, województwo, cały kraj)
  final DateTime firstSeen, lastSeen;
  final DateTime? validTo;
  final bool attribution;
  final List<String> reasons;
  final List<FeedSource> sources;

  FeedEvent({
    required this.id, required this.type, required this.place, required this.powiat,
    required this.verdict, required this.summary, required this.snippet,
    required this.severity, required this.credibility, required this.lat, required this.lon,
    required this.radiusKm, required this.firstSeen, required this.lastSeen, this.validTo,
    required this.attribution, required this.reasons, required this.sources,
  });

  bool get nationwide => radiusKm >= 390;

  factory FeedEvent.fromJson(Map<String, dynamic> j) => FeedEvent(
        id: j['id'], type: j['type'], place: j['place'], powiat: j['powiat'] ?? '',
        verdict: j['verdict'], summary: j['summary'] ?? '', snippet: j['snippet'] ?? '',
        severity: (j['severity'] as num).toInt(), credibility: (j['credibility'] as num).toInt(),
        lat: (j['lat'] as num).toDouble(), lon: (j['lon'] as num).toDouble(),
        radiusKm: ((j['radius_km'] ?? 0) as num).toDouble(),
        firstSeen: DateTime.parse(j['first_seen']), lastSeen: DateTime.parse(j['last_seen']),
        validTo: j['valid_to'] == null ? null : DateTime.parse(j['valid_to']),
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

const typeLabels = {
  'power': 'Brak prądu', 'water': 'Woda', 'weather': 'Pogoda', 'disaster': 'Żywioł',
  'infrastructure': 'Infrastruktura', 'epidemic': 'Epidemia', 'unrest': 'Niepokoje',
  'shortage': 'Braki w sklepach', 'sabotage': 'Sabotaż', 'other': 'Inne',
};
const verdictLabels = {
  'confirmed': 'Potwierdzone', 'likely': 'Prawdopodobne',
  'unverified': 'Niepotwierdzone', 'dubious': 'Podejrzane',
};

/// Typy zdarzeń pogrupowane w 6 przełączników (zamiast 10).
class TypeGroup {
  final String id, label;
  final List<String> types;
  const TypeGroup(this.id, this.label, this.types);
}

const typeGroups = [
  TypeGroup('utilities', 'Prąd i woda', ['power', 'water']),
  TypeGroup('weather', 'Pogoda (wichury, mrozy, upały, burze)', ['weather']),
  TypeGroup('disaster', 'Klęski żywiołowe (pożary, powodzie)', ['disaster']),
  TypeGroup('infra', 'Infrastruktura (banki, urzędy, łączność)', ['infrastructure']),
  TypeGroup('health', 'Zagrożenia epidemiologiczne', ['epidemic']),
  TypeGroup('security', 'Bezpieczeństwo (niepokoje, sklepy, sabotaż)', ['unrest', 'shortage', 'sabotage', 'other']),
];

/// Tryb czujności zastępuje cztery suwaki.
class Mode {
  final String label;
  final int minSeverity, notifySeverity;
  final double nearbyKm;
  const Mode(this.label, this.minSeverity, this.nearbyKm, this.notifySeverity);
}

const modes = [
  Mode('Spokojny', 4, 25, 5),
  Mode('Standard', 3, 40, 4),
  Mode('Czujny', 2, 80, 3),
];

class Settings {
  int mode;
  int theme;            // 0 = jak w systemie, 1 = jasny, 2 = ciemny
  bool showDubious;
  bool showShelters;    // warstwa schronów na mapie
  double shelterKm;     // promień szukania schronów wokół punktu odniesienia (1 / 2 / 5)
  Set<String> groups;
  String feedUrl;
  List<Pin> pins;

  Settings({this.mode = 1, this.theme = 0, this.showDubious = true, this.showShelters = true, this.shelterKm = 2.0, Set<String>? groups, this.feedUrl = defaultFeedUrl, List<Pin>? pins})
      : groups = groups ?? typeGroups.map((g) => g.id).toSet(),
        pins = pins ?? [];

  Mode get _m => modes[mode.clamp(0, modes.length - 1).toInt()];
  int get minSeverity => _m.minSeverity;
  int get notifySeverity => _m.notifySeverity;
  double get nearbyKm => _m.nearbyKm;
  double get safeKm => _m.nearbyKm * 2;   // powyżej: "jesteś z dala od zdarzenia"

  bool allows(String type) =>
      typeGroups.any((g) => groups.contains(g.id) && g.types.contains(type));

  Map<String, dynamic> toJson() => {
        'mode': mode, 'theme': theme, 'showDubious': showDubious, 'showShelters': showShelters, 'shelterKm': shelterKm, 'groups': groups.toList(),
        'feedUrl': feedUrl, 'pins': pins.map((p) => p.toJson()).toList(),
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        mode: j['mode'] ?? 1,
        theme: j['theme'] ?? 0,
        showDubious: j['showDubious'] ?? true,
        showShelters: j['showShelters'] ?? true,
        shelterKm: ((j['shelterKm'] ?? 2) as num).toDouble(),
        groups: j['groups'] == null ? null : Set<String>.from(j['groups']),
        feedUrl: ((j['feedUrl'] as String?)?.trim().isNotEmpty ?? false) ? j['feedUrl'] : defaultFeedUrl,
        pins: ((j['pins'] ?? []) as List).map((p) => Pin.fromJson(Map<String, dynamic>.from(p))).toList(),
      );
}
