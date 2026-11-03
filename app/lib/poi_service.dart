import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'poi.dart';

/// poi.json (obiekty z OSM) obok feed.json; kopia w pamięci telefonu, odświeżana najwyżej raz na 24 h.
class PoiService {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/poi.json');
  }

  static Uri urlFor(String feedUrl) => Uri.parse(feedUrl).resolve('poi.json');

  static Future<PoiSet?> cached() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      return await compute(parsePoi, await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<PoiSet?> refresh(String feedUrl, {bool force = false}) async {
    try {
      final f = await _file();
      if (!force && await f.exists() && DateTime.now().difference(await f.lastModified()) < const Duration(hours: 24)) {
        return null;
      }
      final r = await http.get(urlFor(feedUrl)).timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) return null;
      final set = await compute(parsePoi, r.body); // walidacja przed zapisem
      await f.writeAsString(r.body);
      return set;
    } catch (_) {
      return null;
    }
  }
}
