import 'package:flutter/cupertino.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:workmanager/workmanager.dart';

import 'background.dart';
import 'feed_service.dart';
import 'geo.dart';
import 'models.dart';
import 'notifier.dart';
import 'relevance.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifier.init(askPermission: true);
  try {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      'watchpl-poll', 'watchpl-poll',
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (_) {}
  runApp(const WatchApp());
}

// ---------- stan aplikacji ----------

class AppState extends ChangeNotifier {
  Settings settings = Settings();
  Feed? feed;
  LatLon? pos;
  LatLon? focus;                 // "Pokaż na mapie"
  bool locationOk = false;
  String? error;
  final tabs = CupertinoTabController();

  Future<void> init() async {
    settings = await Store.loadSettings();
    feed = await FeedService.cached();
    pos = await Store.loadLastPos();
    notifyListeners();
    try {
      if (await Geolocator.checkPermission() == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
    } catch (_) {}
    await refresh();
  }

  Future<void> refresh() async {
    error = null;
    await _locate();
    if (settings.feedUrl.isEmpty) {
      error = 'Ustaw adres feedu w zakładce Ustawienia';
    } else {
      try {
        feed = await FeedService.fetch(settings.feedUrl);
      } catch (_) {
        error = 'Nie udało się pobrać danych (pokazuję ostatnie znane)';
      }
    }
    notifyListeners();
  }

  Future<void> _locate() async {
    locationOk = false;
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
      ).timeout(const Duration(seconds: 15));
      pos = LatLon(p.latitude, p.longitude);
      locationOk = true;
      await Store.saveLastPos(pos!);
    } catch (_) {}
  }

  Future<void> save() async {
    await Store.saveSettings(settings);
    notifyListeners();
  }

  void showOnMap(FeedEvent e) {
    focus = LatLon(e.lat, e.lon);
    tabs.index = 1;
    notifyListeners();
  }
}

// ---------- pomocnicze ----------

Color sevColor(int s) => s >= 4
    ? CupertinoColors.systemRed
    : s == 3 ? CupertinoColors.systemOrange : CupertinoColors.systemYellow;

Color verdictColor(String v) => switch (v) {
      'confirmed' => CupertinoColors.systemGreen,
      'likely' => CupertinoColors.systemBlue,
      'unverified' => CupertinoColors.systemOrange,
      _ => CupertinoColors.systemRed,
    };

String ago(DateTime t) {
  final m = DateTime.now().difference(t).inMinutes;
  if (m < 1) return 'przed chwilą';
  if (m < 60) return '$m min temu';
  if (m < 48 * 60) return '${m ~/ 60} h temu';
  return '${m ~/ 1440} dni temu';
}

String fmtDate(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}.${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
}

Color secondary(BuildContext c) => CupertinoColors.secondaryLabel.resolveFrom(c);

// ---------- aplikacja ----------

class WatchApp extends StatefulWidget {
  const WatchApp({super.key});
  @override
  State<WatchApp> createState() => _WatchAppState();
}

class _WatchAppState extends State<WatchApp> {
  final st = AppState();

  @override
  void initState() {
    super.initState();
    st.init();
  }

  @override
  Widget build(BuildContext context) => CupertinoApp(
        title: 'WatchPL',
        debugShowCheckedModeBanner: false,
        theme: const CupertinoThemeData(primaryColor: CupertinoColors.systemBlue),
        home: CupertinoTabScaffold(
          controller: st.tabs,
          tabBar: CupertinoTabBar(items: const [
            BottomNavigationBarItem(icon: Icon(CupertinoIcons.bell_fill), label: 'Alerty'),
            BottomNavigationBarItem(icon: Icon(CupertinoIcons.map_fill), label: 'Mapa'),
            BottomNavigationBarItem(icon: Icon(CupertinoIcons.location_fill), label: 'Miejsca'),
            BottomNavigationBarItem(icon: Icon(CupertinoIcons.slider_horizontal_3), label: 'Ustawienia'),
          ]),
          tabBuilder: (_, i) => switch (i) {
            0 => AlertsTab(st),
            1 => MapTab(st),
            2 => PlacesTab(st),
            _ => SettingsTab(st),
          },
        ),
      );
}

// ---------- zakładka: Alerty ----------

class AlertsTab extends StatelessWidget {
  final AppState st;
  const AlertsTab(this.st, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final rel = st.feed == null ? <Relevance>[] : evaluate(st.feed!.events, st.settings, st.pos);
          return CupertinoPageScaffold(
            backgroundColor: CupertinoColors.systemGroupedBackground,
            child: CustomScrollView(slivers: [
              const CupertinoSliverNavigationBar(largeTitle: Text('Alerty')),
              CupertinoSliverRefreshControl(onRefresh: st.refresh),
              SliverToBoxAdapter(child: _StatusCard(st)),
              if (rel.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Brak zdarzeń spełniających Twoje kryteria.\n\nPamiętaj: brak alertu nie oznacza, że wszystko jest w porządku — zobacz pokrycie danych powyżej.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: secondary(context)),
                    ),
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: CupertinoListSection.insetGrouped(
                    children: [for (final r in rel) _tile(context, r)],
                  ),
                ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ]),
          );
        },
      );

  Widget _tile(BuildContext context, Relevance r) {
    final e = r.event;
    final note = r.zoneNote(st.settings.safeKm);
    return CupertinoListTile.notched(
      leading: Container(
        width: 30, height: 30, alignment: Alignment.center,
        decoration: BoxDecoration(color: sevColor(e.severity), shape: BoxShape.circle),
        child: Text('${e.severity}',
            style: const TextStyle(color: CupertinoColors.white, fontWeight: FontWeight.w700)),
      ),
      title: Text(e.summary),
      subtitle: Text([typeLabels[e.type] ?? e.type, r.proximity, if (note != null) note]
          .where((x) => x.isNotEmpty).join('\n')),
      additionalInfo: Text(verdictLabels[e.verdict] ?? e.verdict,
          style: TextStyle(color: verdictColor(e.verdict), fontWeight: FontWeight.w600)),
      trailing: const CupertinoListTileChevron(),
      onTap: () => Navigator.of(context)
          .push(CupertinoPageRoute(builder: (_) => DetailPage(st, r))),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final AppState st;
  const _StatusCard(this.st);

  String _mark(dynamic v) => switch (v) { 'good' => '✓', 'partial' => '◐', _ => '✕' };

  @override
  Widget build(BuildContext context) {
    final cov = st.feed?.coverage ?? {};
    const names = [
      ['weather', 'pogoda'], ['disaster', 'żywioły'], ['power', 'prąd'], ['water', 'woda'],
      ['infrastructure', 'infrastruktura'], ['epidemic', 'epidemie'],
      ['unrest', 'niepokoje'], ['shortage', 'sklepy'],
    ];
    final lines = <String>[
      if (st.error != null) st.error!,
      if (st.feed != null) 'Dane z ${ago(st.feed!.generatedAt)}',
      st.locationOk
          ? 'Lokalizacja: aktywna'
          : 'Lokalizacja: brak — działają tylko Twoje punkty (zakładka Miejsca)',
      if (cov.isNotEmpty) 'Pokrycie: ${names.map((n) => '${n[1]} ${_mark(cov[n[0]])}').join(' · ')}',
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(lines.join('\n'), style: TextStyle(fontSize: 13, height: 1.4, color: secondary(context))),
    );
  }
}

class DetailPage extends StatelessWidget {
  final AppState st;
  final Relevance r;
  const DetailPage(this.st, this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final e = r.event;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(middle: Text(e.place)),
      child: SafeArea(
        child: ListView(children: [
          CupertinoListSection.insetGrouped(header: const Text('OCENA'), children: [
            CupertinoListTile(title: const Text('Zdarzenie'), additionalInfo: Text(e.summary)),
            CupertinoListTile(
              title: const Text('Werdykt'),
              additionalInfo: Text(verdictLabels[e.verdict] ?? e.verdict,
                  style: TextStyle(color: verdictColor(e.verdict), fontWeight: FontWeight.w600)),
            ),
            CupertinoListTile(title: const Text('Wiarygodność'), additionalInfo: Text('${e.credibility}%')),
            CupertinoListTile(title: const Text('Ważność'), additionalInfo: Text('${e.severity}/5')),
            if (r.proximity.isNotEmpty)
              CupertinoListTile(title: const Text('Bliskość'), additionalInfo: Text(r.proximity)),
            if (e.validTo != null)
              CupertinoListTile(title: const Text('Obowiązuje do'), additionalInfo: Text(fmtDate(e.validTo!))),
            CupertinoListTile(
                title: const Text('Pierwsze / ostatnie doniesienie'),
                additionalInfo: Text('${ago(e.firstSeen)} / ${ago(e.lastSeen)}')),
            if (!e.nationwide)
              CupertinoListTile(
                leading: const Icon(CupertinoIcons.map),
                title: const Text('Pokaż na mapie'),
                trailing: const CupertinoListTileChevron(),
                onTap: () {
                  Navigator.of(context).pop();
                  st.showOnMap(e);
                },
              ),
          ]),
          CupertinoListSection.insetGrouped(header: const Text('DLACZEGO TAKA OCENA'), children: [
            for (final reason in e.reasons)
              CupertinoListTile(
                leading: const Icon(CupertinoIcons.info_circle, size: 20),
                title: Text(reason, maxLines: 4),
              ),
          ]),
          CupertinoListSection.insetGrouped(header: const Text('ŹRÓDŁA'), children: [
            for (final s in e.sources)
              CupertinoListTile(title: Text(s.name), additionalInfo: Text(s.kind)),
          ]),
          if (e.snippet.isNotEmpty)
            CupertinoListSection.insetGrouped(
              header: const Text('FRAGMENT (TREŚĆ ZEWNĘTRZNA, NIEZWERYFIKOWANA)'),
              children: [CupertinoListTile(title: Text(e.snippet, maxLines: 8))],
            ),
        ]),
      ),
    );
  }
}

// ---------- zakładka: Mapa ----------

class MapTab extends StatefulWidget {
  final AppState st;
  const MapTab(this.st, {super.key});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final _mc = MapController();

  LatLng get _start {
    final st = widget.st;
    final f = st.focus ?? st.pos ?? (st.settings.pins.isNotEmpty
        ? LatLon(st.settings.pins.first.lat, st.settings.pins.first.lon)
        : const LatLon(53.1, 21.3));
    return LatLng(f.lat, f.lon);
  }

  void _applyFocus() {
    final f = widget.st.focus;
    if (f == null) return;
    widget.st.focus = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _mc.move(LatLng(f.lat, f.lon), 11);
      } catch (_) {}   // mapa jeszcze nie gotowa - użyto initialCenter
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.st,
        builder: (context, _) {
          final st = widget.st;
          final events = st.feed == null
              ? <FeedEvent>[]
              : filterEvents(st.feed!.events, st.settings).where((e) => !e.nationwide).toList();
          final center = _start;
          _applyFocus();
          return CupertinoPageScaffold(
            navigationBar: CupertinoNavigationBar(
              middle: const Text('Mapa'),
              backgroundColor: CupertinoColors.systemBackground.resolveFrom(context),
            ),
            child: Stack(children: [
              FlutterMap(
                mapController: _mc,
                options: MapOptions(initialCenter: center, initialZoom: st.focus != null ? 11 : 8),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'pl.watchpl.watchpl',
                  ),
                  CircleLayer(circles: [
                    for (final p in st.settings.pins)
                      CircleMarker(
                        point: LatLng(p.lat, p.lon), radius: p.radiusKm * 1000, useRadiusInMeter: true,
                        color: CupertinoColors.systemBlue.withValues(alpha: 0.06),
                        borderColor: CupertinoColors.systemBlue.withValues(alpha: 0.6), borderStrokeWidth: 1.5,
                      ),
                    for (final e in events.where((e) => e.radiusKm > 0))
                      CircleMarker(
                        point: LatLng(e.lat, e.lon), radius: e.radiusKm * 1000, useRadiusInMeter: true,
                        color: sevColor(e.severity).withValues(alpha: e.verdict == 'dubious' ? 0.08 : 0.2),
                        borderColor: sevColor(e.severity).withValues(alpha: 0.8), borderStrokeWidth: 1.5,
                      ),
                  ]),
                  MarkerLayer(markers: [
                    for (final p in st.settings.pins)
                      Marker(
                        point: LatLng(p.lat, p.lon), width: 32, height: 32,
                        child: const Icon(CupertinoIcons.location_solid, color: CupertinoColors.systemBlue, size: 30),
                      ),
                    if (st.pos != null)
                      Marker(
                        point: LatLng(st.pos!.lat, st.pos!.lon), width: 20, height: 20,
                        child: Container(
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemBlue, shape: BoxShape.circle,
                            border: Border.all(color: CupertinoColors.white, width: 3),
                          ),
                        ),
                      ),
                    for (final e in events) _eventMarker(context, e),
                  ]),
                ],
              ),
              Positioned(
                left: 8, bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  color: CupertinoColors.white.withValues(alpha: 0.75),
                  child: const Text('© OpenStreetMap  ·  kółka: zasięg  ·  ?: podejrzane',
                      style: TextStyle(fontSize: 10, color: CupertinoColors.black)),
                ),
              ),
              if (st.pos != null)
                Positioned(
                  right: 12, top: 12,
                  child: CupertinoButton.filled(
                    padding: const EdgeInsets.all(10),
                    borderRadius: BorderRadius.circular(22),
                    onPressed: () => _mc.move(LatLng(st.pos!.lat, st.pos!.lon), 10),
                    child: const Icon(CupertinoIcons.location_fill, size: 20),
                  ),
                ),
            ]),
          );
        },
      );

  Marker _eventMarker(BuildContext context, FeedEvent e) {
    final dubious = e.verdict == 'dubious';
    final st = widget.st;
    return Marker(
      point: LatLng(e.lat, e.lon), width: 34, height: 34,
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(CupertinoPageRoute(
            builder: (_) => DetailPage(st, relevanceFor(e, st.settings, st.pos)))),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: dubious ? CupertinoColors.systemGrey : sevColor(e.severity),
            shape: BoxShape.circle,
            border: Border.all(color: CupertinoColors.white, width: 2),
          ),
          child: Text(dubious ? '?' : '${e.severity}',
              style: const TextStyle(color: CupertinoColors.white, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

// ---------- zakładka: Miejsca ----------

class PlacesTab extends StatelessWidget {
  final AppState st;
  const PlacesTab(this.st, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) => CupertinoPageScaffold(
          backgroundColor: CupertinoColors.systemGroupedBackground,
          child: CustomScrollView(slivers: [
            CupertinoSliverNavigationBar(
              largeTitle: const Text('Miejsca'),
              trailing: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => _add(context),
                child: const Icon(CupertinoIcons.add),
              ),
            ),
            SliverToBoxAdapter(
              child: CupertinoListSection.insetGrouped(
                header: const Text('PUNKTY MONITOROWANE NIEZALEŻNIE OD TWOJEJ LOKALIZACJI'),
                footer: const Text('Dostaniesz alert o zdarzeniach w promieniu punktu, nawet gdy jesteś daleko.'),
                children: [
                  if (st.settings.pins.isEmpty)
                    const CupertinoListTile(title: Text('Brak punktów — dodaj dom lub pracę (+)')),
                  for (final p in st.settings.pins)
                    CupertinoListTile(
                      leading: const Icon(CupertinoIcons.location_solid),
                      title: Text(p.name),
                      subtitle: Text('${p.lat.toStringAsFixed(4)}, ${p.lon.toStringAsFixed(4)}'),
                      additionalInfo: Text('${p.radiusKm.round()} km'),
                      onTap: () => _remove(context, p),
                    ),
                ],
              ),
            ),
          ]),
        ),
      );

  void _remove(BuildContext context, Pin p) => showCupertinoModalPopup(
        context: context,
        builder: (_) => CupertinoActionSheet(
          title: Text(p.name),
          actions: [
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                st.settings.pins.remove(p);
                st.save();
                Navigator.pop(context);
              },
              child: const Text('Usuń punkt'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context), child: const Text('Anuluj')),
        ),
      );

  void _add(BuildContext context) {
    final name = TextEditingController();
    final coords = TextEditingController(
        text: st.pos == null ? '' : '${st.pos!.lat.toStringAsFixed(5)}, ${st.pos!.lon.toStringAsFixed(5)}');
    final radius = TextEditingController(text: '25');
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Nowy punkt'),
        content: Column(children: [
          const SizedBox(height: 8),
          CupertinoTextField(controller: name, placeholder: 'Nazwa (np. Dom)'),
          const SizedBox(height: 8),
          CupertinoTextField(
              controller: coords, placeholder: 'szer., dł. (np. 52.88, 20.62)',
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true)),
          const SizedBox(height: 8),
          CupertinoTextField(
              controller: radius, placeholder: 'Promień (km)', keyboardType: TextInputType.number),
          const SizedBox(height: 6),
          const Text('Współrzędne: domyślnie Twoja bieżąca pozycja — wklej inne z map, jeśli dodajesz dom będąc gdzie indziej.',
              style: TextStyle(fontSize: 11)),
        ]),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              final parts = coords.text.split(RegExp(r'[,;\s]+')).where((x) => x.isNotEmpty).toList();
              final lat = parts.length == 2 ? double.tryParse(parts[0]) : null;
              final lon = parts.length == 2 ? double.tryParse(parts[1]) : null;
              final r = double.tryParse(radius.text.replaceAll(',', '.')) ?? 25;
              if (name.text.trim().isEmpty || lat == null || lon == null) return;
              st.settings.pins.add(Pin(name.text.trim(), lat, lon, r.clamp(1, 300).toDouble()));
              st.save();
              Navigator.pop(ctx);
            },
            child: const Text('Dodaj'),
          ),
        ],
      ),
    );
  }
}

// ---------- zakładka: Ustawienia ----------

class SettingsTab extends StatelessWidget {
  final AppState st;
  const SettingsTab(this.st, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final s = st.settings;
          final m = modes[s.mode.clamp(0, modes.length - 1).toInt()];
          return CupertinoPageScaffold(
            backgroundColor: CupertinoColors.systemGroupedBackground,
            child: CustomScrollView(slivers: [
              const CupertinoSliverNavigationBar(largeTitle: Text('Ustawienia')),
              SliverToBoxAdapter(
                child: Column(children: [
                  CupertinoListSection.insetGrouped(
                    header: const Text('CZUJNOŚĆ'),
                    footer: Text('${m.label}: ważność od ${m.minSeverity}/5, w promieniu ${m.nearbyKm.round()} km '
                        'od Ciebie i Twoich punktów, powiadomienia od ${m.notifySeverity}/5.'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: CupertinoSlidingSegmentedControl<int>(
                          groupValue: s.mode,
                          children: {for (var i = 0; i < modes.length; i++) i: Text(modes[i].label)},
                          onValueChanged: (v) {
                            if (v != null) {
                              s.mode = v;
                              st.save();
                            }
                          },
                        ),
                      ),
                      CupertinoListTile(
                        title: const Text('Pokazuj zdarzenia podejrzane'),
                        subtitle: const Text('Z flagą i uzasadnieniem; bez powiadomień'),
                        trailing: CupertinoSwitch(
                            value: s.showDubious, onChanged: (v) { s.showDubious = v; st.save(); }),
                      ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(header: const Text('CO MONITOROWAĆ'), children: [
                    for (final g in typeGroups)
                      CupertinoListTile(
                        title: Text(g.label),
                        trailing: CupertinoSwitch(
                          value: s.groups.contains(g.id),
                          onChanged: (v) { v ? s.groups.add(g.id) : s.groups.remove(g.id); st.save(); },
                        ),
                      ),
                  ]),
                  CupertinoListSection.insetGrouped(
                    header: const Text('ŹRÓDŁO DANYCH'),
                    footer: const Text('Adres feed.json z Twojego repozytorium (gałąź data).'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: CupertinoTextField(
                          controller: TextEditingController(text: s.feedUrl),
                          placeholder: 'https://raw.githubusercontent.com/…/data/feed.json',
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          onSubmitted: (v) { s.feedUrl = v.trim(); st.save(); st.refresh(); },
                          onTapOutside: (_) => FocusScope.of(context).unfocus(),
                        ),
                      ),
                    ],
                  ),
                  CupertinoListSection.insetGrouped(
                    header: const Text('UPRAWNIENIA'),
                    footer: const Text('Alerty o punktach (dom, praca) działają bez lokalizacji. Dla alertów wokół Ciebie w tle ustaw lokalizację „Zawsze" w ustawieniach systemu.'),
                    children: [
                      CupertinoListTile(
                        title: const Text('Lokalizacja'),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () async {
                          await Geolocator.requestPermission();
                          await Geolocator.openAppSettings();
                        },
                      ),
                      CupertinoListTile(
                        title: const Text('Powiadomienia'),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => Notifier.init(askPermission: true),
                      ),
                      CupertinoListTile(
                        title: const Text('Sprawdź teraz i powiadom'),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => checkAndNotify(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                ]),
              ),
            ]),
          );
        },
      );
}
