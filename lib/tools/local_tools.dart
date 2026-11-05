import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';

import '../data/assistant.dart';
import 'calculator.dart';
import 'tool.dart';

List<AppTool> buildLocalTools(Set<LocalTool> enabled) => [
  if (enabled.contains(LocalTool.timeInfo))
    AppTool(
      name: 'get_time_info',
      displayName: 'Time',
      description: 'Get the current local date, time, weekday and timezone of the user.',
      parameters: objectSchema({}),
      execute: (_) async {
        final now = DateTime.now();
        return jsonEncode({
          'iso': now.toIso8601String(),
          'weekday': const [
            'Monday',
            'Tuesday',
            'Wednesday',
            'Thursday',
            'Friday',
            'Saturday',
            'Sunday',
          ][now.weekday - 1],
          'timezone': now.timeZoneName,
          'utc_offset_minutes': now.timeZoneOffset.inMinutes,
          'unix': now.millisecondsSinceEpoch ~/ 1000,
        });
      },
    ),
  if (enabled.contains(LocalTool.clipboard))
    AppTool(
      name: 'clipboard',
      displayName: 'Clipboard',
      description: 'Read text from or write text to the system clipboard.',
      needsApproval: true,
      parameters: objectSchema(
        {
          'action': strProp('read or write', enumValues: ['read', 'write']),
          'text': strProp('Text to write (only for write)'),
        },
        required: ['action'],
      ),
      execute: (args) async {
        if (args['action'] == 'write') {
          await Clipboard.setData(ClipboardData(text: '${args['text'] ?? ''}'));
          return jsonEncode({'ok': true});
        }
        final d = await Clipboard.getData(Clipboard.kTextPlain);
        return jsonEncode({'text': d?.text ?? ''});
      },
    ),
  if (enabled.contains(LocalTool.deviceInfo))
    AppTool(
      name: 'get_device_info',
      displayName: 'Device',
      description: 'Get basic device info: OS, version, locale and battery level.',
      parameters: objectSchema({}),
      execute: (_) async {
        int? battery;
        try {
          battery = await Battery().batteryLevel;
        } catch (_) {}
        return jsonEncode({
          'os': Platform.operatingSystem,
          'os_version': Platform.operatingSystemVersion,
          'locale': Platform.localeName,
          'battery_percent': battery,
        });
      },
    ),
  if (enabled.contains(LocalTool.calculator))
    AppTool(
      name: 'calculate',
      displayName: 'Calculator',
      description: 'Evaluate an arithmetic expression precisely. Supports + - * / % ^ ( ), sqrt, sin, cos, tan, log, ln, exp, abs, pi, e.',
      parameters: objectSchema({'expression': strProp('The expression, e.g. (3+4)^2/7')}, required: ['expression']),
      execute: (args) async {
        try {
          final v = Calculator.eval('${args['expression'] ?? ''}');
          final out = v is double && v == v.roundToDouble() && v.abs() < 1e15 ? v.toInt() : v;
          return jsonEncode({'result': out});
        } catch (e) {
          return jsonEncode({'error': e.toString()});
        }
      },
    ),
];
