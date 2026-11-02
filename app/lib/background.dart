import 'package:geolocator/geolocator.dart';
import 'package:workmanager/workmanager.dart';
import 'feed_service.dart';
import 'geo.dart';
import 'models.dart';
import 'notifier.dart';
import 'relevance.dart';
import 'store.dart';

/// Pozycja: spróbuj świeżej (wymaga zgody; w tle "zawsze"), inaczej ostatnia zapisana przez aplikację.
Future<LatLon?> currentOrLastPos({bool allowFresh = true}) async {
  if (allowFresh) {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.always || perm == LocationPermission.whileInUse) {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
        ).timeout(const Duration(seconds: 15));
        final pos = LatLon(p.latitude, p.longitude);
        await Store.saveLastPos(pos);
        return pos;
      }
    } catch (_) {}
  }
  return Store.loadLastPos();
}

/// Jedno sprawdzenie: pobierz feed, dopasuj do lokalizacji i punktów, powiadom o nowych.
Future<int> checkAndNotify() async {
  final s = await Store.loadSettings();
  if (s.feedUrl.isEmpty) return 0;
  final feed = await FeedService.fetch(s.feedUrl);
  final me = await currentOrLastPos();
  final notified = await Store.loadNotified();
  var sent = 0;
  for (final r in evaluate(feed.events, s, me)) {
    final e = r.event;
    if (e.severity < s.notifySeverity || e.verdict == 'dubious') continue;
    final key = '${e.id}:${e.verdict}';
    if (notified.contains(key)) continue;
    await Notifier.show(
      e.id.hashCode & 0x7fffffff,
      '${e.place}: ${typeLabels[e.type] ?? e.type} (${verdictLabels[e.verdict]})',
      [r.proximity, r.zoneNote(s.safeKm)].whereType<String>().where((x) => x.isNotEmpty).join(' · '),
    );
    notified.add(key);
    sent++;
  }
  await Store.saveNotified(notified);
  return sent;
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      await Notifier.init();
      await checkAndNotify();
    } catch (_) {}
    return true;
  });
}
