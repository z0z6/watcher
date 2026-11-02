import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'store.dart';

class FeedService {
  static Future<Feed> fetch(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final body = utf8.decode(r.bodyBytes);
    final feed = Feed.fromJson(jsonDecode(body));
    await Store.saveFeedCache(body);
    return feed;
  }

  static Future<Feed?> cached() async {
    final raw = await Store.loadFeedCache();
    return raw == null ? null : Feed.fromJson(jsonDecode(raw));
  }
}
