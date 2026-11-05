import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// All persistent files live inside the app sandbox.
///
/// iOS: Application Support (backed up, not user visible) + Caches for temp data.
/// Android: app-internal files dir. Nothing is written to shared storage without
/// an explicit user action (share sheet / save dialog / photo library).
class AppPaths {
  static late Directory support;
  static late Directory cache;

  static Future<void> init() async {
    support = await getApplicationSupportDirectory();
    cache = await getTemporaryDirectory();
    for (final d in [files, avatars, backgrounds, exports]) {
      await d.create(recursive: true);
    }
  }

  static Directory get files => Directory(p.join(support.path, 'files'));
  static Directory get avatars => Directory(p.join(support.path, 'avatars'));
  static Directory get backgrounds => Directory(p.join(support.path, 'backgrounds'));
  static Directory get exports => Directory(p.join(cache.path, 'exports'));

  static String get dbPath => p.join(support.path, 'mewhub.db');
  static String get settingsPath => p.join(support.path, 'settings.json');

  /// Stored paths are relative to [support] so they survive iOS container UUID
  /// changes after app updates / restores.
  static String toRelative(String abs) {
    if (abs.startsWith(support.path)) {
      return abs.substring(support.path.length).replaceAll(r'\', '/').replaceFirst(RegExp(r'^/'), '');
    }
    return abs;
  }

  static String resolve(String stored) {
    if (stored.startsWith('http://') || stored.startsWith('https://') || stored.startsWith('data:')) {
      return stored;
    }
    if (p.isAbsolute(stored)) {
      if (File(stored).existsSync()) return stored;
      // Old absolute path from a previous container: try to remap.
      final idx = stored.indexOf('/files/');
      if (idx >= 0) return p.join(support.path, stored.substring(idx + 1));
      return stored;
    }
    return p.join(support.path, stored);
  }

  static Future<int> dirSize(Directory d) async {
    if (!await d.exists()) return 0;
    var total = 0;
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }
}
