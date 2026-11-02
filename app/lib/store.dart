import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'geo.dart';
import 'models.dart';

class Store {
  static Future<Settings> loadSettings() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('settings');
    return raw == null ? Settings() : Settings.fromJson(jsonDecode(raw));
  }

  static Future<void> saveSettings(Settings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('settings', jsonEncode(s.toJson()));
  }

  static Future<void> saveLastPos(LatLon pos) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lastPos', jsonEncode([pos.lat, pos.lon]));
  }

  static Future<LatLon?> loadLastPos() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('lastPos');
    if (raw == null) return null;
    final l = jsonDecode(raw) as List;
    return LatLon((l[0] as num).toDouble(), (l[1] as num).toDouble());
  }

  static Future<void> saveFeedCache(String json) async =>
      (await SharedPreferences.getInstance()).setString('feedCache', json);

  static Future<String?> loadFeedCache() async =>
      (await SharedPreferences.getInstance()).getString('feedCache');

  /// Zdarzenia już widziane w aplikacji (do wykrywania NOWYCH na mapie).
  static Future<Set<String>> loadSeen() async =>
      ((await SharedPreferences.getInstance()).getStringList('seen') ?? []).toSet();

  static Future<void> saveSeen(Set<String> s) async {
    final list = s.toList();
    final tail = list.length > 500 ? list.sublist(list.length - 500) : list;
    await (await SharedPreferences.getInstance()).setStringList('seen', tail);
  }

  static Future<Set<String>> loadNotified() async =>
      ((await SharedPreferences.getInstance()).getStringList('notified') ?? []).toSet();

  static Future<void> saveNotified(Set<String> s) async {
    final list = s.toList();
    final tail = list.length > 300 ? list.sublist(list.length - 300) : list;
    await (await SharedPreferences.getInstance()).setStringList('notified', tail);
  }
}
