import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notifier {
  static final _p = FlutterLocalNotificationsPlugin();

  static Future<void> init({bool askPermission = false}) async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _p.initialize(const InitializationSettings(android: android));
    if (askPermission) {
      await _p
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  static Future<void> show(int id, String title, String body) => _p.show(
        id, title, body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'alerts', 'Alerty',
            channelDescription: 'Zdarzenia spełniające Twoje kryteria',
            importance: Importance.high, priority: Priority.high,
          ),
        ),
      );
}
