import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();

String asStr(dynamic v, [String def = '']) => v is String ? v : (v == null ? def : v.toString());

String? asStrOrNull(dynamic v) => v is String ? v : v?.toString();

int asInt(dynamic v, [int def = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? def;
  return def;
}

int? asIntOrNull(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? asDoubleOrNull(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

double asDouble(dynamic v, [double def = 0]) => asDoubleOrNull(v) ?? def;

bool asBool(dynamic v, [bool def = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return def;
}

Map<String, dynamic> asMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return <String, dynamic>{};
}

Map<String, dynamic>? asMapOrNull(dynamic v) => v is Map ? asMap(v) : null;

List<dynamic> asList(dynamic v) => v is List ? v : const [];

List<T> mapList<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    asList(v).whereType<Map<dynamic, dynamic>>().map((e) => f(asMap(e))).toList();

T enumByName<T extends Enum>(List<T> values, dynamic name, T def) {
  if (name is! String) return def;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return def;
}

Set<T> enumSet<T extends Enum>(List<T> values, dynamic list) {
  final out = <T>{};
  for (final n in asList(list)) {
    for (final v in values) {
      if (v.name == n) out.add(v);
    }
  }
  return out;
}

DateTime dateFromMs(dynamic v) => DateTime.fromMillisecondsSinceEpoch(asInt(v, DateTime.now().millisecondsSinceEpoch));

DateTime? dateFromMsOrNull(dynamic v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(asInt(v));

dynamic tryJsonDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

String prettyJson(Object? v) => const JsonEncoder.withIndent('  ').convert(v);

/// Deep-merges [patch] into [base]. Maps merge recursively, everything else replaces.
Map<String, dynamic> deepMerge(Map<String, dynamic> base, Map<String, dynamic> patch) {
  final out = Map<String, dynamic>.from(base);
  patch.forEach((k, v) {
    final cur = out[k];
    if (cur is Map && v is Map) {
      out[k] = deepMerge(asMap(cur), asMap(v));
    } else {
      out[k] = v;
    }
  });
  return out;
}

String formatTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K';
  return '$n';
}

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String twoDigits(int n) => n.toString().padLeft(2, '0');

String formatDateTime(DateTime d) =>
    '${d.year}-${twoDigits(d.month)}-${twoDigits(d.day)} ${twoDigits(d.hour)}:${twoDigits(d.minute)}';

String formatTime(DateTime d) => '${twoDigits(d.hour)}:${twoDigits(d.minute)}';

String formatDate(DateTime d) => '${d.year}-${twoDigits(d.month)}-${twoDigits(d.day)}';

String randomHex(int bytes) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String truncate(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';
