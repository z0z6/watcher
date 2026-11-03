import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'shelters.dart';

/// Pobiera shelters.json z gałęzi data (obok feed.json) i trzyma kopię w pamięci telefonu,
/// żeby lista schronów działała także bez internetu.
class ShelterService {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/shelters.json');
  }

  static Uri urlFor(String feedUrl) => Uri.parse(feedUrl).resolve('shelters.json');

  static Future<ShelterSet?> cached() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      return await compute(parseShelters, await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Odświeża najwyżej raz na 24 h (plik PSP zmienia się raz w tygodniu). Przy błędzie sieci zwraca null.
  static Future<ShelterSet?> refresh(String feedUrl, {bool force = false}) async {
    try {
      final f = await _file();
      if (!force && await f.exists() && DateTime.now().difference(await f.lastModified()) < const Duration(hours: 24)) {
        return null; // kopia świeża
      }
      final r = await http.get(urlFor(feedUrl)).timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) return null;
      final body = r.body;
      final set = await compute(parseShelters, body); // walidacja przed zapisem
      await f.writeAsString(body);
      return set;
    } catch (_) {
      return null;
    }
  }
}
