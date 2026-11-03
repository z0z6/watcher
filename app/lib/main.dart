import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';

import 'background.dart';
import 'feed_service.dart';
import 'geo.dart';
import 'models.dart';
import 'notifier.dart';
import 'relevance.dart';
import 'share.dart';
import 'share_text.dart';
import 'shelter_service.dart';
import 'shelters.dart';
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

// ---------- paleta (jasny i ciemny motyw) ----------
// Ciemny: czarno-zielone tło i kolory ostrzegawcze w stylu paneli OSINT. Jasny: neutralny.

const appBg = CupertinoDynamicColor.withBrightness(color: Color(0xFFF2F4F2), darkColor: Color(0xFF0A0F0A));
const appCard = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF121A12));
const appBorder = CupertinoDynamicColor.withBrightness(color: Color(0x26000000), darkColor: Color(0x3322C55E));
const cRed = CupertinoDynamicColor.withBrightness(color: Color(0xFFDC2626), darkColor: Color(0xFFF87171));
const cAmber = CupertinoDynamicColor.withBrightness(color: Color(0xFFD97706), darkColor: Color(0xFFFBBF24));
const cGray = CupertinoDynamicColor.withBrightness(color: Color(0xFF64748B), darkColor: Color(0xFF94A3B8));
const cGreen = CupertinoDynamicColor.withBrightness(color: Color(0xFF16A34A), darkColor: Color(0xFF4ADE80));
const cBlue = CupertinoDynamicColor.withBrightness(color: Color(0xFF2563EB), darkColor: Color(0xFF60A5FA));

/// Ważność -> kolor: czerwony (4-5), żółty (3), szary (1-2) - jak poziomy na panelach OSINT.
Color sevColor(BuildContext c, int s) => (s >= 4 ? cRed : s == 3 ? cAmber : cGray).resolveFrom(c);

Color verdictColor(BuildContext c, String v) => (switch (v) {
      'confirmed' => cGreen,
      'likely' => cBlue,
      'unverified' => cAmber,
      _ => cRed,
    })
        .resolveFrom(c);

Color secondary(BuildContext c) => CupertinoColors.secondaryLabel.resolveFrom(c);
bool isDark(BuildContext c) => CupertinoTheme.brightnessOf(c) == Brightness.dark;

Widget section(BuildContext c, List<Widget> children, {Widget? header, Widget? footer}) =>
    CupertinoListSection.insetGrouped(
        backgroundColor: appBg.resolveFrom(c), header: header, footer: footer, children: children);

/// Otwiera link w przeglądarce (do samodzielnej weryfikacji źródła).
Future<void> openLink(String url) async {
  final u = Uri.tryParse(url);
  if (u == null || !(u.scheme == 'https' || u.scheme == 'http')) return;
  try {
    await launchUrl(u, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

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

// ---------- stan aplikacji ----------

class AppState extends ChangeNotifier {
  Settings settings = Settings();
  Feed? feed;
  LatLon? pos;
  LatLon? focus;                         // "Pokaż na mapie"
  bool locationOk = false;
  String? error;
  final tabs = CupertinoTabController();

  Set<String> seen = {};                 // zdarzenia już widziane
  final Map<String, DateTime> fresh = {};// id -> do kiedy oznaczone jako NOWE
  FeedEvent? toast;                      // baner "nowe zdarzenie"
  int toastCount = 0;
  ShelterSet? shelters;                  // punkty schronienia (PSP) z obszaru monitorowania
  int shelterAnchor = -1;                // punkt odniesienia: -1 = Ty, 0.. = indeks punktu (Dom, Praca...)
  Timer? _toastTimer, _tick, _auto;

  bool isFresh(String id) => (fresh[id]?.isAfter(DateTime.now())) ?? false;

  Future<void> init() async {
    settings = await Store.loadSettings();
    feed = await FeedService.cached();
    pos = await Store.loadLastPos();
    seen = await Store.loadSeen();
    notifyListeners();
    unawaited(_loadShelters());
    try {
      if (await Geolocator.checkPermission() == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
    } catch (_) {}
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {   // wygaszanie znaczników NOWE
      final n = DateTime.now();
      final before = fresh.length;
      fresh.removeWhere((_, until) => until.isBefore(n));
      if (before != fresh.length) notifyListeners();
    });
    _auto = Timer.periodic(const Duration(minutes: 3), (_) => refresh());   // tryb LIVE
    await refresh();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _tick?.cancel();
    _auto?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    error = null;
    await _locate();
    if (settings.feedUrl.trim().isEmpty) settings.feedUrl = defaultFeedUrl;
    try {
      feed = await FeedService.fetch(settings.feedUrl);
      await _detectNew();
    } catch (_) {
      error = 'Nie udało się pobrać danych (pokazuję ostatnie znane)';
    }
    unawaited(_loadShelters());
    notifyListeners();
  }

  /// NOWE = id, którego jeszcze nie widziałeś. Przy pierwszym uruchomieniu nie alarmujemy o wszystkim.
  Future<void> _detectNew() async {
    final f = feed!;
    final firstRun = seen.isEmpty;
    final newOnes = filterEvents(f.events, settings).where((e) => !seen.contains(e.id)).toList();
    seen.addAll(f.events.map((e) => e.id));
    await Store.saveSeen(seen);
    if (firstRun || newOnes.isEmpty) return;
    final until = DateTime.now().add(const Duration(minutes: 10));
    for (final e in newOnes) {
      fresh[e.id] = until;
    }
    newOnes.sort((a, b) => b.severity.compareTo(a.severity));
    toast = newOnes.first;
    toastCount = newOnes.length;
    HapticFeedback.mediumImpact();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 8), dismissToast);
  }

  void dismissToast() {
    toast = null;
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

  Future<void> _loadShelters() async {
    try {
      shelters ??= await ShelterService.cached();   // kopia lokalna działa bez internetu
      notifyListeners();
      final fresh = await ShelterService.refresh(settings.feedUrl);
      if (fresh != null) {
        shelters = fresh;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Punkt odniesienia dla schronów: Ty (GPS) albo wybrany punkt (Dom, Praca...).
  int get anchorIndex {
    if (shelterAnchor >= 0 && shelterAnchor < settings.pins.length) return shelterAnchor;
    if (pos != null) return -1;
    return settings.pins.isNotEmpty ? 0 : -1;
  }

  LatLon? pointFor(int i) =>
      (i >= 0 && i < settings.pins.length) ? LatLon(settings.pins[i].lat, settings.pins[i].lon) : pos;

  LatLon? get anchorPoint => pointFor(anchorIndex);

  String get anchorLabel {
    final i = anchorIndex;
    if (i >= 0) return settings.pins[i].name;
    return pos != null ? 'Ja' : '—';
  }

  List<ShelterHit> sheltersNear({int limit = 100}) {
    final a = anchorPoint, set = shelters;
    if (a == null || set == null) return const [];
    return set.nearest(a.lat, a.lon, settings.shelterKm, limit: limit);
  }

  void setAnchor(int i) {
    shelterAnchor = i;
    notifyListeners();
  }

  void showSheltersAround(int pinIndex) {
    shelterAnchor = pinIndex;
    tabs.index = 2;
    notifyListeners();
  }

  void showShelterOnMap(Shelter s) {
    focus = LatLon(s.lat, s.lon);
    settings.showShelters = true;
    Store.saveSettings(settings);
    tabs.index = 1;
    notifyListeners();
  }

  void showOnMap(FeedEvent e) {
    focus = LatLon(e.lat, e.lon);
    tabs.index = 1;
    notifyListeners();
  }
}

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
  void dispose() {
    st.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final t = st.settings.theme;
          return CupertinoApp(
            title: 'WatchPL',
            debugShowCheckedModeBanner: false,
            theme: CupertinoThemeData(
              brightness: t == 1 ? Brightness.light : t == 2 ? Brightness.dark : null,
              primaryColor: cBlue,
              scaffoldBackgroundColor: appBg,
              barBackgroundColor: appCard,
            ),
            home: Builder(
              builder: (ctx) => Stack(fit: StackFit.expand, children: [
                CupertinoTabScaffold(
                  controller: st.tabs,
                  tabBar: CupertinoTabBar(items: const [
                    BottomNavigationBarItem(icon: Icon(CupertinoIcons.bell_fill), label: 'Alerty'),
                    BottomNavigationBarItem(icon: Icon(CupertinoIcons.map_fill), label: 'Mapa'),
                    BottomNavigationBarItem(icon: Icon(CupertinoIcons.shield_fill), label: 'Schrony'),
                    BottomNavigationBarItem(icon: Icon(CupertinoIcons.location_fill), label: 'Miejsca'),
                    BottomNavigationBarItem(icon: Icon(CupertinoIcons.slider_horizontal_3), label: 'Ustawienia'),
                  ]),
                  tabBuilder: (_, i) => switch (i) {
                    0 => AlertsTab(st),
                    1 => MapTab(st),
                    2 => SheltersTab(st),
                    3 => PlacesTab(st),
                    _ => SettingsTab(st),
                  },
                ),
                Positioned(
                  top: MediaQuery.of(ctx).padding.top + 8, left: 12, right: 12,
                  child: _Toast(st),
                ),
              ]),
            ),
          );
        },
      );
}

/// Baner "NOWE ZDARZENIE" wsuwany od góry (z wibracją), dotknięcie przenosi na mapę.
class _Toast extends StatelessWidget {
  final AppState st;
  const _Toast(this.st);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final e = st.toast;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, anim) => SlideTransition(
              position: Tween(begin: const Offset(0, -1.4), end: Offset.zero).animate(anim),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: e == null
                ? const SizedBox.shrink(key: ValueKey('none'))
                : GestureDetector(
                    key: ValueKey(e.id),
                    onTap: () {
                      st.dismissToast();
                      st.showOnMap(e);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: appCard.resolveFrom(context).withValues(alpha: 0.97),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: sevColor(context, e.severity), width: 1.5),
                        boxShadow: [BoxShadow(color: sevColor(context, e.severity).withValues(alpha: 0.35), blurRadius: 18)],
                      ),
                      child: Row(children: [
                        _PulseDot(color: sevColor(context, e.severity), period: const Duration(milliseconds: 1200),
                            isNew: true, box: 44, core: 12),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                              st.toastCount > 1 ? 'NOWE ZDARZENIA · ${st.toastCount}' : 'NOWE ZDARZENIE',
                              style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w700,
                                  color: sevColor(context, e.severity)),
                            ),
                            const SizedBox(height: 2),
                            Text(e.summary, maxLines: 2, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            Text('${typeLabels[e.type] ?? e.type} · ${verdictLabels[e.verdict] ?? e.verdict}',
                                style: TextStyle(fontSize: 12, color: secondary(context))),
                          ]),
                        ),
                        Icon(CupertinoIcons.chevron_right, size: 16, color: secondary(context)),
                      ]),
                    ),
                  ),
          );
        },
      );
}

// ---------- pulsujący punkt ----------

/// Rdzeń + powoli rozchodzący się pierścień. isNew dokłada szybszy, jaśniejszy "ping".
class _PulseDot extends StatefulWidget {
  final Color color;
  final Duration period;
  final bool pulse, isNew;
  final double box, core, phase;
  const _PulseDot({
    super.key,
    required this.color, required this.period, this.pulse = true, this.isNew = false,
    this.box = 64, this.core = 14, this.phase = 0,
  });
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period);
  late final AnimationController _n =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    _c.value = widget.phase;
    if (widget.pulse) _c.repeat();
    if (widget.isNew) _n.repeat();
  }

  @override
  void didUpdateWidget(_PulseDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) _c.repeat();
    if (!widget.pulse) _c.stop();
    if (widget.isNew && !_n.isAnimating) _n.repeat();
    if (!widget.isNew) _n.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    _n.dispose();
    super.dispose();
  }

  Widget _ring(double p, double span, double alpha, double width) {
    final base = widget.box * 0.46;
    return Opacity(
      opacity: ((1 - p) * alpha).clamp(0.0, 1.0),
      child: Transform.scale(
        scale: 0.5 + p * span,
        child: Container(
          width: base, height: base,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.12),
            border: Border.all(color: widget.color, width: width),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.box, height: widget.box,
        child: AnimatedBuilder(
          animation: Listenable.merge([_c, _n]),
          builder: (_, __) => Stack(alignment: Alignment.center, children: [
            if (widget.pulse) _ring(Curves.easeOut.transform(_c.value), 1.6, 0.6, 1.5),
            if (widget.isNew) _ring(_n.value, 1.7, 0.95, 2.5),
            Container(
              width: widget.core, height: widget.core,
              decoration: BoxDecoration(
                color: widget.color, shape: BoxShape.circle,
                border: Border.all(color: CupertinoColors.white.withValues(alpha: 0.85), width: 1.5),
                boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.7), blurRadius: 10)],
              ),
            ),
          ]),
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
            backgroundColor: appBg.resolveFrom(context),
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
                SliverToBoxAdapter(child: section(context, [for (final r in rel) _tile(context, r)])),
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ]),
          );
        },
      );

  Widget _tile(BuildContext context, Relevance r) {
    final e = r.event;
    final note = r.zoneNote(st.settings.safeKm);
    final isNew = st.isFresh(e.id);
    return CupertinoListTile.notched(
      leading: Container(
        width: 30, height: 30, alignment: Alignment.center,
        decoration: BoxDecoration(color: sevColor(context, e.severity), shape: BoxShape.circle),
        child: Text('${e.severity}',
            style: const TextStyle(color: CupertinoColors.white, fontWeight: FontWeight.w700)),
      ),
      title: Text(e.summary),
      subtitle: Text.rich(TextSpan(children: [
        if (isNew)
          TextSpan(
              text: '● NOWE  ',
              style: TextStyle(color: sevColor(context, e.severity), fontWeight: FontWeight.w700, letterSpacing: 1)),
        TextSpan(
            text: [typeLabels[e.type] ?? e.type, r.proximity, if (note != null) note]
                .where((x) => x.isNotEmpty).join('\n')),
      ])),
      additionalInfo: Text(verdictLabels[e.verdict] ?? e.verdict,
          style: TextStyle(color: verdictColor(context, e.verdict), fontWeight: FontWeight.w600)),
      trailing: const CupertinoListTileChevron(),
      onTap: () => Navigator.of(context).push(CupertinoPageRoute(builder: (_) => DetailPage(st, r))),
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
        color: appCard.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: appBorder.resolveFrom(context)),
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
      backgroundColor: appBg.resolveFrom(context),
      navigationBar: CupertinoNavigationBar(middle: Text(e.place)),
      child: SafeArea(
        child: ListView(children: [
          section(context, header: const Text('OCENA'), [
            CupertinoListTile(title: const Text('Zdarzenie'), additionalInfo: Text(e.summary)),
            CupertinoListTile(
              title: const Text('Werdykt'),
              additionalInfo: Text(verdictLabels[e.verdict] ?? e.verdict,
                  style: TextStyle(color: verdictColor(context, e.verdict), fontWeight: FontWeight.w600)),
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
          section(context, header: const Text('UDOSTĘPNIJ'), [
            CupertinoListTile(
              leading: const Icon(CupertinoIcons.share),
              title: const Text('Udostępnij zdarzenie…'),
              subtitle: const Text('Signal, Messenger, SMS, e-mail…'),
              trailing: const CupertinoListTileChevron(),
              onTap: () => shareText(eventText(e, proximity: r.proximity), subject: e.summary),
            ),
            if (!e.nationwide)
              CupertinoListTile(
                leading: const Icon(CupertinoIcons.location),
                title: const Text('Udostępnij lokalizację zdarzenia'),
                trailing: const CupertinoListTileChevron(),
                onTap: () => shareText(locationText(e.place, e.lat, e.lon), subject: e.place),
              ),
            CupertinoListTile(
              leading: const Icon(CupertinoIcons.doc_on_doc),
              title: const Text('Skopiuj opis'),
              onTap: () {
                copyText(eventText(e, proximity: r.proximity));
                flash(context, 'Skopiowano do schowka');
              },
            ),
          ]),
          section(context, header: const Text('DLACZEGO TAKA OCENA'), [
            for (final reason in e.reasons)
              CupertinoListTile(
                leading: const Icon(CupertinoIcons.info_circle, size: 20),
                title: Text(reason, maxLines: 4),
              ),
          ]),
          section(context, header: const Text('ŹRÓDŁA'), [
            for (final s in e.sources)
              CupertinoListTile(
                title: Text(s.title.isNotEmpty ? s.title : s.name, maxLines: 3, overflow: TextOverflow.ellipsis),
                subtitle: Text([s.name, kindLabels[s.kind] ?? s.kind, if (s.published != null) ago(s.published!)]
                    .where((x) => x.isNotEmpty).join(' · ')),
                trailing: s.openable ? Icon(CupertinoIcons.arrow_up_right_square, size: 20, color: cBlue.resolveFrom(context)) : null,
                onTap: s.openable ? () => openLink(s.url) : null,
              ),
          ]),
          if (e.sources.any((s) => s.openable))
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 12),
              child: Text('Dotknij źródła, żeby otworzyć oryginalny artykuł lub komunikat i sprawdzić samemu, '
                  'czy taka informacja faktycznie się pojawiła.',
                  style: TextStyle(fontSize: 12, color: secondary(context))),
            ),
          if (e.snippet.isNotEmpty)
            section(context,
                header: const Text('FRAGMENT (TREŚĆ ZEWNĘTRZNA, NIEZWERYFIKOWANA)'),
                [CupertinoListTile(title: Text(e.snippet, maxLines: 8))]),
        ]),
      ),
    );
  }
}

// ---------- zakładka: Mapa ----------

// Kafelki OpenStreetMap (bez klucza API). Ciemny motyw: odwrócenie kolorów + ściemnienie filtrem.
const _tiles = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _darkMatrix = <double>[
  -0.85, 0, 0, 0, 217,
  0, -0.9, 0, 0, 225,
  0, 0, -0.8, 0, 200,
  0, 0, 0, 1, 0,
];
const _neCenter = LatLng(53.6, 22.0);   // środek północno-wschodniej Polski

class MapTab extends StatefulWidget {
  final AppState st;
  const MapTab(this.st, {super.key});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final _mc = MapController();
  String? _selected, _hovered;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  LatLng get _start {
    final st = widget.st;
    final f = st.focus ?? st.pos;
    return f == null ? _neCenter : LatLng(f.lat, f.lon);
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

  void _hover(String id, bool on) {
    _hideTimer?.cancel();
    if (on) {
      setState(() => _hovered = id);
    } else {
      _hideTimer = Timer(const Duration(milliseconds: 350), () {
        if (mounted) setState(() => _hovered = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.st,
        builder: (context, _) {
          final st = widget.st;
          final dark = isDark(context);
          final events = st.feed == null
              ? <FeedEvent>[]
              : filterEvents(st.feed!.events, st.settings).where((e) => !e.nationwide).toList();
          final focusing = st.focus != null;
          final center = _start;
          _applyFocus();
          final openId = _selected ?? _hovered;
          final open = events.where((e) => e.id == openId).firstOrNull;
          final newCount = events.where((e) => st.isFresh(e.id)).length;
          final showSh = st.settings.showShelters && st.shelters != null;
          final shelterHits = showSh ? st.sheltersNear(limit: 150) : <ShelterHit>[];
          final anchor = showSh ? st.anchorPoint : null;
          final anchors = <(String, int)>[
            if (st.pos != null) ('Ja', -1),
            for (var i = 0; i < st.settings.pins.length; i++) (st.settings.pins[i].name, i),
          ];

          return CupertinoPageScaffold(
            navigationBar: CupertinoNavigationBar(middle: const Text('Mapa'), backgroundColor: appCard.resolveFrom(context)),
            child: Stack(children: [
              FlutterMap(
                mapController: _mc,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: focusing ? 11 : (st.pos != null ? 9 : 7),
                  onTap: (_, __) => setState(() { _selected = null; _hovered = null; }),
                ),
                children: [
                  dark
                      ? ColorFiltered(
                          key: const ValueKey('tiles-dark'),
                          colorFilter: const ColorFilter.matrix(_darkMatrix),
                          child: TileLayer(urlTemplate: _tiles, userAgentPackageName: 'pl.watchpl.watchpl'),
                        )
                      : TileLayer(
                          key: const ValueKey('tiles-light'),
                          urlTemplate: _tiles,
                          userAgentPackageName: 'pl.watchpl.watchpl',
                        ),
                  CircleLayer(circles: [
                    if (anchor != null)
                      CircleMarker(
                        point: LatLng(anchor.lat, anchor.lon), radius: st.settings.shelterKm * 1000, useRadiusInMeter: true,
                        color: cGreen.resolveFrom(context).withValues(alpha: 0.06),
                        borderColor: cGreen.resolveFrom(context).withValues(alpha: 0.55), borderStrokeWidth: 1.2,
                      ),
                    for (final p in st.settings.pins)
                      CircleMarker(
                        point: LatLng(p.lat, p.lon), radius: p.radiusKm * 1000, useRadiusInMeter: true,
                        color: cBlue.resolveFrom(context).withValues(alpha: 0.07),
                        borderColor: cBlue.resolveFrom(context).withValues(alpha: 0.6), borderStrokeWidth: 1.2,
                      ),
                    for (final e in events.where((e) => e.radiusKm > 0))
                      CircleMarker(
                        point: LatLng(e.lat, e.lon), radius: e.radiusKm * 1000, useRadiusInMeter: true,
                        color: sevColor(context, e.severity).withValues(alpha: e.verdict == 'dubious' ? 0.05 : 0.13),
                        borderColor: sevColor(context, e.severity).withValues(alpha: 0.55), borderStrokeWidth: 1,
                      ),
                  ]),
                  MarkerLayer(markers: [
                    for (final p in st.settings.pins)
                      Marker(
                        point: LatLng(p.lat, p.lon), width: 32, height: 32,
                        child: Icon(CupertinoIcons.location_solid, color: cBlue.resolveFrom(context), size: 30),
                      ),
                    if (st.pos != null)
                      Marker(
                        point: LatLng(st.pos!.lat, st.pos!.lon), width: 20, height: 20,
                        child: Container(
                          decoration: BoxDecoration(
                            color: cBlue.resolveFrom(context), shape: BoxShape.circle,
                            border: Border.all(color: CupertinoColors.white, width: 3),
                          ),
                        ),
                      ),
                    for (final h in shelterHits)
                      Marker(
                        point: LatLng(h.s.lat, h.s.lon), width: 30, height: 30,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => showShelterActions(context, st, h.s, h.km),
                          child: Center(
                            child: Container(
                              width: 13, height: 13,
                              decoration: BoxDecoration(
                                color: availColor(context, h.s.d), shape: BoxShape.circle,
                                border: Border.all(color: CupertinoColors.white, width: 1.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    for (final e in events) _dotMarker(context, e),
                    if (open != null) _popupMarker(context, open),
                  ]),
                ],
              ),
              Positioned(
                left: 12, top: 12,
                child: _LivePill(feed: st.feed, count: events.length, fresh: newCount),
              ),
              Positioned(
                left: 8, bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: appCard.resolveFrom(context).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('© OpenStreetMap contributors · kółka: zasięg · ?: podejrzane${showSh ? ' · schrony: KG PSP, dane.gov.pl (stan ${st.shelters!.stanPl})' : ''}',
                      style: TextStyle(fontSize: 10, color: secondary(context))),
                ),
              ),
              Positioned(
                right: 12, top: 12,
                child: Column(children: [
                  if (st.pos != null) ...[
                    _RoundBtn(icon: CupertinoIcons.location_fill, onTap: () => _mc.move(LatLng(st.pos!.lat, st.pos!.lon), 10)),
                    const SizedBox(height: 8),
                  ],
                  _RoundBtn(
                    icon: CupertinoIcons.shield_fill, active: st.settings.showShelters,
                    onTap: () {
                      st.settings.showShelters = !st.settings.showShelters;
                      st.save();
                    },
                  ),
                  if (st.pos != null) ...[
                    const SizedBox(height: 8),
                    _RoundBtn(
                      icon: CupertinoIcons.share,
                      onTap: () => shareText(locationText('Moja lokalizacja', st.pos!.lat, st.pos!.lon), subject: 'Moja lokalizacja'),
                    ),
                  ],
                ]),
              ),
              if (st.settings.showShelters && anchors.isNotEmpty)
                Positioned(
                  left: 8, right: 8, bottom: 34,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final a in anchors)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _Chip(
                            label: 'Schrony: ${a.$1}',
                            selected: st.anchorIndex == a.$2,
                            onTap: () {
                              st.setAnchor(a.$2);
                              final p = st.pointFor(a.$2);
                              if (p != null) _mc.move(LatLng(p.lat, p.lon), 14);
                            },
                          ),
                        ),
                    ]),
                  ),
                ),
            ]),
          );
        },
      );

  /// Punkt zdarzenia: im ważniejsze, tym szybciej pulsuje. Podejrzane = szare, bez pulsu.
  Marker _dotMarker(BuildContext context, FeedEvent e) {
    final st = widget.st;
    final dubious = e.verdict == 'dubious';
    final color = dubious ? cGray.resolveFrom(context) : sevColor(context, e.severity);
    final period = e.severity >= 4
        ? const Duration(milliseconds: 1800)
        : e.severity == 3 ? const Duration(milliseconds: 2800) : const Duration(milliseconds: 4200);
    return Marker(
      point: LatLng(e.lat, e.lon), width: 64, height: 64,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _hover(e.id, true),     // najechanie myszą/rysikiem
        onExit: (_) => _hover(e.id, false),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => setState(() => _selected = _selected == e.id ? null : e.id),   // dotyk
          child: _PulseDot(
            key: ValueKey('dot-${e.id}-${st.isFresh(e.id)}'),
            color: color, period: period, pulse: !dubious, isNew: st.isFresh(e.id),
            phase: (e.id.hashCode % 100) / 100,
          ),
        ),
      ),
    );
  }

  /// Rozwijana karta nad punktem. Marker ma stałą wysokość, a karta stoi na jego dolnej krawędzi.
  Marker _popupMarker(BuildContext context, FeedEvent e) {
    final st = widget.st;
    final r = relevanceFor(e, st.settings, st.pos);
    const h = 190.0;
    return Marker(
      point: LatLng(e.lat, e.lon), width: 262, height: h * 2,
      child: Column(children: [
        SizedBox(
          height: h,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 30),
              child: _Popup(
                r: r, isNew: st.isFresh(e.id),
                onHover: (on) => _hover(e.id, on),
                onOpen: () => Navigator.of(context).push(CupertinoPageRoute(builder: (_) => DetailPage(st, r))),
                onShare: () => shareText(eventText(e, proximity: r.proximity), subject: e.summary),
              ),
            ),
          ),
        ),
        const SizedBox(height: h),
      ]),
    );
  }
}

class _Popup extends StatelessWidget {
  final Relevance r;
  final bool isNew;
  final ValueChanged<bool> onHover;
  final VoidCallback onOpen, onShare;
  const _Popup({required this.r, required this.isNew, required this.onHover, required this.onOpen, required this.onShare});

  @override
  Widget build(BuildContext context) {
    final e = r.event;
    final c = sevColor(context, e.severity);
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        onTap: onOpen,
        child: Container(
          width: 250,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: appCard.resolveFrom(context).withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.withValues(alpha: 0.8), width: 1.2),
            boxShadow: [BoxShadow(color: CupertinoColors.black.withValues(alpha: 0.35), blurRadius: 14)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('WAŻNOŚĆ ${e.severity}/5',
                  style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: c)),
              if (isNew)
                Text('  ● NOWE', style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: c)),
              const Spacer(),
              Text(verdictLabels[e.verdict] ?? e.verdict,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: verdictColor(context, e.verdict))),
            ]),
            const SizedBox(height: 5),
            Text(e.summary, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text([typeLabels[e.type] ?? e.type, if (r.proximity.isNotEmpty) r.proximity].join(' · '),
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: secondary(context))),
            if (e.reasons.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(e.reasons.first, maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.25)),
            ],
            if (e.sources.any((s) => s.openable)) ...[
              const SizedBox(height: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => openLink(e.sources.firstWhere((s) => s.openable).url),
                child: Row(children: [
                  Icon(CupertinoIcons.arrow_up_right_square, size: 13, color: cBlue.resolveFrom(context)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      () {
                        final s = e.sources.firstWhere((s) => s.openable);
                        return 'Źródło: ${s.name}${s.title.isNotEmpty ? ' — ${s.title}' : ''}';
                      }(),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: cBlue.resolveFrom(context), decoration: TextDecoration.underline),
                    ),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 6),
            Row(children: [
              Text('${ago(e.lastSeen)} · ${e.sources.length} źr.', style: TextStyle(fontSize: 10, color: secondary(context))),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onShare,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(CupertinoIcons.share, size: 16, color: cBlue.resolveFrom(context)),
                ),
              ),
              Text('Szczegóły ›', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cBlue.resolveFrom(context))),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// "LIVE" w rogu mapy: stan danych i licznik zdarzeń.
class _LivePill extends StatelessWidget {
  final Feed? feed;
  final int count, fresh;
  const _LivePill({required this.feed, required this.count, required this.fresh});

  @override
  Widget build(BuildContext context) {
    final live = feed != null && DateTime.now().difference(feed!.generatedAt).inMinutes < 45;
    final c = live ? cGreen.resolveFrom(context) : cGray.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(2, 0, 10, 0),
      decoration: BoxDecoration(
        color: appCard.resolveFrom(context).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: appBorder.resolveFrom(context)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _PulseDot(color: c, period: const Duration(milliseconds: 2000), pulse: live, box: 32, core: 8),
        Text(
          '${live ? 'LIVE' : 'OFFLINE'} · $count${fresh > 0 ? ' · $fresh NOWE' : ''}'
          '${feed == null ? '' : ' · ${ago(feed!.generatedAt)}'}',
          style: TextStyle(fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w600, color: c),
        ),
      ]),
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
          backgroundColor: appBg.resolveFrom(context),
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
              child: section(
                context,
                header: const Text('PUNKTY MONITOROWANE NIEZALEŻNIE OD TWOJEJ LOKALIZACJI'),
                footer: const Text('Dostaniesz alert o zdarzeniach w promieniu punktu, nawet gdy jesteś daleko.'),
                [
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
              onPressed: () {
                Navigator.pop(context);
                st.showSheltersAround(st.settings.pins.indexOf(p));
              },
              child: const Text('Schrony w pobliżu'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(context);
                shareText(locationText(p.name, p.lat, p.lon), subject: p.name);
              },
              child: const Text('Udostępnij lokalizację punktu…'),
            ),
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
            backgroundColor: appBg.resolveFrom(context),
            child: CustomScrollView(slivers: [
              const CupertinoSliverNavigationBar(largeTitle: Text('Ustawienia')),
              SliverToBoxAdapter(
                child: Column(children: [
                  section(
                    context,
                    header: const Text('WYGLĄD'),
                    [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: CupertinoSlidingSegmentedControl<int>(
                          groupValue: s.theme,
                          children: const {0: Text('Auto'), 1: Text('Jasny'), 2: Text('Ciemny')},
                          onValueChanged: (v) {
                            if (v != null) {
                              s.theme = v;
                              st.save();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  section(
                    context,
                    header: const Text('CZUJNOŚĆ'),
                    footer: Text('${m.label}: ważność od ${m.minSeverity}/5, w promieniu ${m.nearbyKm.round()} km '
                        'od Ciebie i Twoich punktów, powiadomienia od ${m.notifySeverity}/5.'),
                    [
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
                  section(context, header: const Text('CO MONITOROWAĆ'), [
                    for (final g in typeGroups)
                      CupertinoListTile(
                        title: Text(g.label),
                        trailing: CupertinoSwitch(
                          value: s.groups.contains(g.id),
                          onChanged: (v) { v ? s.groups.add(g.id) : s.groups.remove(g.id); st.save(); },
                        ),
                      ),
                  ]),
                  section(
                    context,
                    header: const Text('ŹRÓDŁO DANYCH'),
                    footer: Text(st.error != null && s.feedUrl.isNotEmpty
                        ? '⚠ ${st.error}'
                        : st.feed != null && s.feedUrl.isNotEmpty
                            ? '✓ Połączono: ${st.feed!.events.length} zdarzeń w feedzie, dane z ${ago(st.feed!.generatedAt)}.'
                            : 'Wklej adres pliku feed.json z gałęzi „data” Twojego repozytorium i zatwierdź (Enter / „Gotowe”).'),
                    [Padding(padding: const EdgeInsets.all(12), child: _UrlField(st))],
                  ),
                  section(
                    context,
                    header: const Text('SCHRONY'),
                    footer: const Text('Źródło: oficjalny zbiór KG PSP „Punkty schronienia w Polsce” (dane.gov.pl). '
                        'Punkt na mapie nie gwarantuje schronienia ani dostępu - sprawdź na miejscu; w razie zagrożenia '
                        'stosuj się do komunikatów służb (112).'),
                    [
                      CupertinoListTile(
                        title: const Text('Pokazuj schrony na mapie'),
                        trailing: CupertinoSwitch(
                            value: s.showShelters, onChanged: (v) { s.showShelters = v; st.save(); }),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: CupertinoSlidingSegmentedControl<double>(
                          groupValue: s.shelterKm,
                          children: const {1.0: Text('1 km'), 2.0: Text('2 km'), 5.0: Text('5 km')},
                          onValueChanged: (v) {
                            if (v != null) {
                              s.shelterKm = v;
                              st.save();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  section(
                    context,
                    header: const Text('UPRAWNIENIA'),
                    footer: const Text('Alerty o punktach (dom, praca) działają bez lokalizacji. Dla alertów wokół Ciebie w tle ustaw lokalizację „Zawsze" w ustawieniach systemu.'),
                    [
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

/// Pole adresu feedu: własny kontroler (tekst nie "skacze" przy odświeżaniu ekranu),
/// zapis przy zatwierdzeniu albo dotknięciu poza polem.
class _UrlField extends StatefulWidget {
  final AppState st;
  const _UrlField(this.st);
  @override
  State<_UrlField> createState() => _UrlFieldState();
}

class _UrlFieldState extends State<_UrlField> {
  late final TextEditingController _c = TextEditingController(text: widget.st.settings.feedUrl);

  void _commit() {
    final v = _c.text.trim();
    if (v == widget.st.settings.feedUrl) return;
    widget.st.settings.feedUrl = v;
    widget.st.save();
    widget.st.refresh();
  }

  @override
  void dispose() {
    _commit();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoTextField(
        controller: _c,
        placeholder: 'https://raw.githubusercontent.com/UŻYTKOWNIK/REPO/data/feed.json',
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        autocorrect: false,
        enableSuggestions: false,
        clearButtonMode: OverlayVisibilityMode.editing,
        onSubmitted: (_) => _commit(),
        onTapOutside: (_) {
          _commit();
          FocusScope.of(context).unfocus();
        },
      );
}

// ---------- schrony: zakładka, akcje, pomocnicze ----------

Color availColor(BuildContext c, int d) => (d == 0 ? cGreen : d == 1 ? cAmber : cGray).resolveFrom(c);

/// Krótki komunikat potwierdzający (np. "Skopiowano"), znika sam.
void flash(BuildContext context, String msg) {
  showCupertinoDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      Future.delayed(const Duration(milliseconds: 1100), () {
        if (ctx.mounted) Navigator.of(ctx).pop();
      });
      return CupertinoAlertDialog(content: Text(msg));
    },
  );
}

void showShelterActions(BuildContext context, AppState st, Shelter s, double? km) {
  showCupertinoModalPopup(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: Text(s.adres.isEmpty ? 'Punkt schronienia' : s.adres),
      message: Text([s.gmina, availabilityLabels[s.d], if (km != null) '${km.toStringAsFixed(2)} km']
          .where((x) => x.isNotEmpty).join(' · ')),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(ctx);
            openLink(walkLink(s.lat, s.lon));
          },
          child: const Text('Prowadź (trasa piesza, Mapy Google)'),
        ),
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(ctx);
            st.showShelterOnMap(s);
          },
          child: const Text('Pokaż na mapie'),
        ),
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(ctx);
            shareText(shelterText(s, km: km), subject: 'Punkt schronienia');
          },
          child: const Text('Udostępnij…'),
        ),
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(ctx);
            copyText(shelterText(s, km: km));
            flash(context, 'Skopiowano do schowka');
          },
          child: const Text('Skopiuj adres i link'),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
    ),
  );
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? cBlue.resolveFrom(context) : appCard.resolveFrom(context).withValues(alpha: 0.95),
            border: Border.all(color: appBorder.resolveFrom(context)),
            boxShadow: [BoxShadow(color: CupertinoColors.black.withValues(alpha: 0.2), blurRadius: 6)],
          ),
          child: Icon(icon, size: 20, color: active ? CupertinoColors.white : cBlue.resolveFrom(context)),
        ),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? cBlue.resolveFrom(context) : appCard.resolveFrom(context).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: appBorder.resolveFrom(context)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: selected ? CupertinoColors.white : CupertinoColors.label.resolveFrom(context))),
        ),
      );
}

class _InfoCard extends StatelessWidget {
  final List<String> lines;
  const _InfoCard(this.lines);

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: appCard.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: appBorder.resolveFrom(context)),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(lines.join('\n'), style: TextStyle(fontSize: 13, height: 1.4, color: secondary(context))),
        ),
      );
}

/// Zakładka "Schrony": najbliższe punkty schronienia wokół Ciebie, domu, pracy (dane PSP).
class SheltersTab extends StatelessWidget {
  final AppState st;
  const SheltersTab(this.st, {super.key});

  void _pickAnchor(BuildContext context) => showCupertinoModalPopup(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
          title: const Text('Szukaj schronów wokół'),
          actions: [
            if (st.pos != null)
              CupertinoActionSheetAction(
                onPressed: () { Navigator.pop(ctx); st.setAnchor(-1); },
                child: const Text('Ja (bieżąca lokalizacja)'),
              ),
            for (var i = 0; i < st.settings.pins.length; i++)
              CupertinoActionSheetAction(
                onPressed: () { Navigator.pop(ctx); st.setAnchor(i); },
                child: Text(st.settings.pins[i].name),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Anuluj')),
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: st,
        builder: (context, _) {
          final s = st.settings;
          final set = st.shelters;
          final hits = st.sheltersNear(limit: 60);
          final noAnchor = st.anchorPoint == null;
          return CupertinoPageScaffold(
            backgroundColor: appBg.resolveFrom(context),
            child: CustomScrollView(slivers: [
              const CupertinoSliverNavigationBar(largeTitle: Text('Schrony')),
              SliverToBoxAdapter(
                child: Column(children: [
                  section(context, header: const Text('OKOLICA'), [
                    CupertinoListTile(
                      title: const Text('Szukaj wokół'),
                      additionalInfo: Text(st.anchorLabel),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => _pickAnchor(context),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: CupertinoSlidingSegmentedControl<double>(
                        groupValue: s.shelterKm,
                        children: const {1.0: Text('1 km'), 2.0: Text('2 km'), 5.0: Text('5 km')},
                        onValueChanged: (v) {
                          if (v != null) {
                            s.shelterKm = v;
                            st.save();
                          }
                        },
                      ),
                    ),
                    CupertinoListTile(
                      title: const Text('Pokaż na mapie'),
                      trailing: CupertinoSwitch(
                          value: s.showShelters, onChanged: (v) { s.showShelters = v; st.save(); }),
                    ),
                  ]),
                  _InfoCard([
                    if (set == null)
                      'Brak danych o schronach. Sprawdź adres feedu w Ustawieniach i uruchom workflow „feed” (pobiera zbiór PSP).'
                    else
                      'Dane: Komenda Główna PSP, dane.gov.pl · stan ${set.stanPl} · punktów w obszarze: ${set.items.length}'
                          '${set.demo ? ' · DANE DEMONSTRACYJNE' : ''}',
                    if (noAnchor) 'Brak punktu odniesienia: włącz lokalizację albo dodaj punkt w zakładce Miejsca.',
                    'Odległość i czas dojścia liczone w linii prostej (ok. 5 km/h).',
                  ]),
                  if (set != null && !noAnchor && hits.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Brak punktów schronienia w promieniu ${s.shelterKm.round()} km od: ${st.anchorLabel}. Zwiększ promień.\n\n'
                        'Brak punktu w zbiorze nie oznacza, że w okolicy nie ma żadnego miejsca ukrycia.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: secondary(context)),
                      ),
                    )
                  else if (hits.isNotEmpty)
                    section(context, header: Text('NAJBLIŻSZE (${hits.length}${hits.length == 60 ? '+' : ''})'), [
                      for (final h in hits)
                        CupertinoListTile.notched(
                          leading: Container(
                            width: 14, height: 14,
                            decoration: BoxDecoration(color: availColor(context, h.s.d), shape: BoxShape.circle),
                          ),
                          title: Text(h.s.adres.isEmpty ? h.s.gmina : h.s.adres, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${h.s.gmina} · ${availabilityLabels[h.s.d]}'),
                          additionalInfo: Text('${h.distanceLabel} · ~${h.walkMinutes} min'),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () => showShelterActions(context, st, h.s, h.km),
                        ),
                    ]),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
                    child: Text(shelterDisclaimer, style: TextStyle(fontSize: 12, height: 1.35, color: secondary(context))),
                  ),
                ]),
              ),
            ]),
          );
        },
      );
}
