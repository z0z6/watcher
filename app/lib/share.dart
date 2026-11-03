import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Systemowe okno udostępniania Androida: Signal, Messenger, SMS, e-mail itd.
/// (Messenger bywa niedostępny - ograniczenia Meta; wtedy użyj "Skopiuj".)
Future<void> shareText(String text, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));
