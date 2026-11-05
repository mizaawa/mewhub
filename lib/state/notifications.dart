import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local "reply finished" notifications. Permission is requested lazily,
/// only when the user turns the option on.
class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_mewhub'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings: settings);
    _ready = true;
  }

  static Future<bool> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) return await android.requestNotificationsPermission() ?? false;
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) return await ios.requestPermissions(alert: true, sound: true) ?? false;
    return false;
  }

  static Future<void> showDone(String title, String body) async {
    try {
      await init();
      await _plugin.show(
        id: 1001,
        title: title,
        body: body.length > 120 ? '${body.substring(0, 120)}…' : body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'reply',
            'Replies',
            channelDescription: 'Notifies when a reply finishes',
            importance: Importance.defaultImportance,
            icon: '@drawable/ic_stat_mewhub',
            color: Color(0xFFB07D52),
          ),
          iOS: DarwinNotificationDetails(presentAlert: false, presentBanner: false),
        ),
      );
    } catch (_) {}
  }
}
