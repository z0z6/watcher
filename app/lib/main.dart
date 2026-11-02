import 'package:flutter/cupertino.dart';
import 'package:geolocator/geolocator.dart';
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
  bool locationOk = false;
  String? error;

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
          tabBar: CupertinoTabBar(items: const [
            BottomNavigationBarItem(icon: Icon(CupertinoIcons.bell_fill), label: 'Alerty'),
            BottomNavigationBarItem(icon: Icon(CupertinoIcons.location_fill), label: 'Miejsca'),
            BottomNavigationBarItem(icon: Icon(CupertinoIcons.slider_horizontal_3), label: 'Ustawienia'),
          ]),
          tabBuilder: (_, i) => switch (i) {
            0 => AlertsTab(st),
            1 => PlacesTab(st),
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
      title: Text('${e.place} · ${typeLabels[e.type] ?? e.type}'),
      subtitle: Text([r.proximity, if (note != null) note].where((x) => x.isNotEmpty).join('\n')),
      additionalInfo: Text(verdictLabels[e.verdict] ?? e.verdict,
          style: TextStyle(color: verdictColor(e.verdict), fontWeight: FontWeight.w600)),
      trailing: const CupertinoListTileChevron(),
      onTap: () => Navigator.of(context).push(CupertinoPageRoute(builder: (_) => DetailPage(r))),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final AppState st;
  const _StatusCard(this.st);

  String _cov(dynamic v) => switch (v) { 'good' => '✓', 'partial' => '◐', _ => '✕' };

  @override
  Widget build(BuildContext context) {
    final cov = st.feed?.coverage ?? {};
    final lines = <String>[
      if (st.error != null) st.error!,
      if (st.feed != null) 'Dane z ${ago(st.feed!.generatedAt)}',
      st.locationOk
          ? 'Lokalizacja: aktywna'
          : 'Lokalizacja: brak — działają tylko Twoje punkty (zakładka Miejsca)',
      if (cov.isNotEmpty)
        'Pokrycie: prąd ${_cov(cov['power'])}${cov['power_live'] == false ? ' (dane operatora niedostępne)' : ''}'
            ' · woda ${_cov(cov['water'])} · zamieszki ${_cov(cov['unrest'])} · sklepy ${_cov(cov['shortage'])}',
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
  final Relevance r;
  const DetailPage(this.r, {super.key});

  @override
  Widget build(BuildContext context) {
    final e = r.event;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(middle: Text(e.place)),
      child: SafeArea(
        child: ListView(children: [
          CupertinoListSection.insetGrouped(header: const Text('OCENA'), children: [
            CupertinoListTile(
              title: const Text('Werdykt'),
              additionalInfo: Text(verdictLabels[e.verdict] ?? e.verdict,
                  style: TextStyle(color: verdictColor(e.verdict), fontWeight: FontWeight.w600)),
            ),
            CupertinoListTile(title: const Text('Wiarygodność'), additionalInfo: Text('${e.credibility}%')),
            CupertinoListTile(title: const Text('Ważność'), additionalInfo: Text('${e.severity}/5')),
            CupertinoListTile(title: const Text('Bliskość'), additionalInfo: Text(r.proximity)),
            CupertinoListTile(
                title: const Text('Pierwsze / ostatnie doniesienie'),
                additionalInfo: Text('${ago(e.firstSeen)} / ${ago(e.lastSeen)}')),
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

  Widget _slider(BuildContext c, String label, String value, double v, double min, double max,
      int div, ValueChanged<double> on) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label),
          Text(value, style: TextStyle(color: secondary(c))),
        ]),
        CupertinoSlider(value: v, min: min, max: max, divisions: div, onChanged: on),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final s = st.settings;
          return CupertinoPageScaffold(
            backgroundColor: CupertinoColors.systemGroupedBackground,
            child: CustomScrollView(slivers: [
              const CupertinoSliverNavigationBar(largeTitle: Text('Ustawienia')),
              SliverToBoxAdapter(
                child: Column(children: [
                  CupertinoListSection.insetGrouped(header: const Text('KRYTERIA'), children: [
                    _slider(context, 'Minimalna ważność', '${s.minSeverity}/5', s.minSeverity.toDouble(),
                        1, 5, 4, (v) { s.minSeverity = v.round(); st.save(); }),
                    _slider(context, 'Promień wokół Ciebie', '${s.nearbyKm.round()} km', s.nearbyKm,
                        10, 150, 14, (v) { s.nearbyKm = v; st.save(); }),
                    _slider(context, '„Z dala od zdarzenia" od', '${s.safeKm.round()} km', s.safeKm,
                        30, 300, 27, (v) { s.safeKm = v; st.save(); }),
                    _slider(context, 'Powiadomienia od ważności', '${s.notifySeverity}/5',
                        s.notifySeverity.toDouble(), 3, 5, 2, (v) { s.notifySeverity = v.round(); st.save(); }),
                    CupertinoListTile(
                      title: const Text('Pokazuj zdarzenia podejrzane'),
                      subtitle: const Text('Z czerwoną flagą i uzasadnieniem; bez powiadomień'),
                      trailing: CupertinoSwitch(
                          value: s.showDubious, onChanged: (v) { s.showDubious = v; st.save(); }),
                    ),
                  ]),
                  CupertinoListSection.insetGrouped(header: const Text('TYPY ZDARZEŃ'), children: [
                    for (final t in allTypes)
                      CupertinoListTile(
                        title: Text(typeLabels[t]!),
                        trailing: CupertinoSwitch(
                          value: s.types.contains(t),
                          onChanged: (v) { v ? s.types.add(t) : s.types.remove(t); st.save(); },
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
