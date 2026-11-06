import 'dart:math' as math;

import '../ai/message.dart';
import '../core/util.dart';
import 'conversation.dart';

/// A timezone-neutral calendar date. Message timestamps are converted to local
/// time before entering the statistics; iteration then stays correct across DST.
DateTime statisticsDay(DateTime date) => DateTime.utc(date.year, date.month, date.day);

String statisticsDate(DateTime date) => '${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)}';

String statisticsNumber(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
  return '$value';
}

class UsageTotals {
  const UsageTotals({this.input = 0, this.output = 0, this.cached = 0, this.requests = 0});

  final int input;
  final int output;
  final int cached;
  final int requests;
  int get total => input + output;
  double get cacheRate => input == 0 ? 0 : cached / input;

  UsageTotals operator +(UsageTotals other) => UsageTotals(
    input: input + other.input,
    output: output + other.output,
    cached: cached + other.cached,
    requests: requests + other.requests,
  );

  factory UsageTotals.fromRow(Map<String, Object?> row) {
    final input = math.max(0, asInt(row['input_tokens']));
    return UsageTotals(
      input: input,
      output: math.max(0, asInt(row['output_tokens'])),
      cached: asInt(row['cached_tokens']).clamp(0, input),
      requests: math.max(0, asInt(row['requests'])),
    );
  }
}

class UsageRecord {
  const UsageRecord({
    required this.day,
    required this.modelId,
    required this.modelName,
    required this.source,
    required this.usage,
  });

  final DateTime day;
  final String modelId;
  final String modelName;
  final String source;
  final UsageTotals usage;

  factory UsageRecord.fromRow(Map<String, Object?> row) => UsageRecord(
    day: statisticsDay(DateTime.parse(row['day'] as String)),
    modelId: asStr(row['model_id']),
    modelName: asStr(row['model_name']),
    source: asStr(row['source'], 'chat'),
    usage: UsageTotals.fromRow(row),
  );
}

class UsageRanking {
  const UsageRanking(this.id, this.name, this.usage);
  final String id;
  final String name;
  final UsageTotals usage;
}

class UsageDay {
  const UsageDay(this.date, this.usage, {this.end});
  final DateTime date;
  final DateTime? end;
  final UsageTotals usage;
}

class UsageStatistics {
  UsageStatistics({
    required DateTime now,
    this.records = const [],
    this.conversations = 0,
    this.messages = 0,
    this.launches = 0,
    this.firstLaunchDay,
    this.activity = const {},
  }) : today = statisticsDay(now);

  final DateTime today;
  final List<UsageRecord> records;
  final int conversations;
  final int messages;
  final int launches;
  final DateTime? firstLaunchDay;
  final Map<DateTime, int> activity;

  factory UsageStatistics.fromStorage({
    required DateTime now,
    required List<Map<String, Object?>> usageRows,
    required List<Conversation> conversations,
    required List<Map<String, Object?>> launchRows,
  }) {
    final activity = <DateTime, int>{};
    var messages = 0;
    for (final conversation in conversations) {
      for (final node in conversation.nodes) {
        for (final message in node.messages) {
          if ((message.role != Role.user && message.role != Role.assistant) || message.isEmpty) continue;
          final day = statisticsDay(message.createdAt.toLocal());
          activity.update(day, (value) => value + 1, ifAbsent: () => 1);
          messages++;
        }
      }
    }
    final launchDays = launchRows.map((row) => DateTime.parse(row['day'] as String)).toList()..sort();
    return UsageStatistics(
      now: now,
      records: usageRows.map(UsageRecord.fromRow).toList(),
      conversations: conversations.length,
      messages: messages,
      launches: launchRows.fold(0, (sum, row) => sum + asInt(row['launches'])),
      firstLaunchDay: launchDays.isEmpty ? null : statisticsDay(launchDays.first),
      activity: activity,
    );
  }

  DateTime get heatmapStart => today.subtract(Duration(days: today.weekday - 1 + 25 * 7));
  int get activeDays => activity.entries
      .where((entry) => entry.value > 0 && !entry.key.isBefore(heatmapStart) && !entry.key.isAfter(today))
      .length;

  int get currentStreak {
    var day = today;
    if ((activity[day] ?? 0) == 0) day = day.subtract(const Duration(days: 1));
    var count = 0;
    while ((activity[day] ?? 0) > 0) {
      count++;
      day = day.subtract(const Duration(days: 1));
    }
    return count;
  }

  UsagePeriod period(int? days, {DateTime? start, DateTime? end}) {
    final past = records.where((record) => !record.day.isAfter(today)).toList()..sort((a, b) => a.day.compareTo(b.day));
    final periodEnd = statisticsDay(end ?? today);
    final boundedEnd = periodEnd.isAfter(today) ? today : periodEnd;
    final periodStart = start != null
        ? statisticsDay(start)
        : days != null
        ? today.subtract(Duration(days: days - 1))
        : (past.isEmpty ? today : past.first.day);
    final boundedStart = periodStart.isAfter(boundedEnd) ? boundedEnd : periodStart;
    return UsagePeriod(
      start: boundedStart,
      end: boundedEnd,
      records: past.where((record) => !record.day.isBefore(boundedStart) && !record.day.isAfter(boundedEnd)).toList(),
    );
  }
}

class UsagePeriod {
  UsagePeriod({required this.start, required this.end, required this.records});
  final DateTime start;
  final DateTime end;
  final List<UsageRecord> records;
  late final UsageTotals totals = records.fold(const UsageTotals(), (sum, record) => sum + record.usage);
  int get dayCount => end.difference(start).inDays + 1;
  int get dailyAverage => (totals.total / dayCount).round();

  late final List<UsageDay> daily = _daily();
  List<UsageDay> _daily() {
    final values = <DateTime, UsageTotals>{};
    for (final record in records) {
      values.update(record.day, (value) => value + record.usage, ifAbsent: () => record.usage);
    }
    return [
      for (var i = 0; i < dayCount; i++)
        UsageDay(start.add(Duration(days: i)), values[start.add(Duration(days: i))] ?? const UsageTotals()),
    ];
  }

  UsageDay get peak => daily.reduce((a, b) => a.usage.total >= b.usage.total ? a : b);
  int get activeDays => daily.where((day) => day.usage.requests > 0 || day.usage.total > 0).length;

  /// Keep long histories readable while preserving every token in the chart.
  int get bucketDays => dayCount <= 90 ? 1 : (dayCount <= 365 ? 7 : 30);
  List<UsageDay> get chartDays {
    if (bucketDays == 1) return daily;
    return [
      for (var i = 0; i < daily.length; i += bucketDays)
        UsageDay(
          daily[i].date,
          daily.skip(i).take(bucketDays).fold(const UsageTotals(), (sum, day) => sum + day.usage),
          end: daily[math.min(i + bucketDays - 1, daily.length - 1)].date,
        ),
    ];
  }

  List<UsageRanking> get models => _rank(false);
  List<UsageRanking> get sources => _rank(true);
  List<UsageRanking> _rank(bool bySource) {
    final values = <String, UsageTotals>{};
    final names = <String, String>{};
    for (final record in records) {
      final key = bySource ? record.source : record.modelId;
      values.update(key, (value) => value + record.usage, ifAbsent: () => record.usage);
      if (record.modelName.isNotEmpty || !names.containsKey(key)) names[key] = record.modelName;
    }
    return [for (final entry in values.entries) UsageRanking(entry.key, names[entry.key] ?? '', entry.value)]
      ..sort((a, b) {
        final order = b.usage.total.compareTo(a.usage.total);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
  }

  String toCsv() {
    String cell(String text) {
      // Spreadsheet programs must treat provider-controlled model names as text.
      final safe = RegExp(r'^[=+\-@\t\r]').hasMatch(text) ? "'$text" : text;
      return '"${safe.replaceAll('"', '""')}"';
    }

    return [
      'date,source,model_id,model_name,requests,input_tokens,cached_tokens,output_tokens,total_tokens',
      for (final record in records)
        [
          statisticsDate(record.day),
          cell(record.source),
          cell(record.modelId),
          cell(record.modelName),
          record.usage.requests,
          record.usage.input,
          record.usage.cached,
          record.usage.output,
          record.usage.total,
        ].join(','),
    ].join('\r\n');
  }
}
