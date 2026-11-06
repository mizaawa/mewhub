import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/usage_statistics.dart';
import 'package:mewhub/ui/pages/usage_stats_page.dart';
import 'package:mewhub/ui/theme.dart';

UsageStatistics fixture() => UsageStatistics(
  now: DateTime(2026, 11, 6),
  conversations: 4,
  messages: 12,
  launches: 3,
  activity: {statisticsDay(DateTime(2026, 11, 5)): 2, statisticsDay(DateTime(2026, 11, 6)): 4},
  records: [
    UsageRecord(
      day: statisticsDay(DateTime(2026, 10, 1)),
      modelId: 'model-b',
      modelName: 'Model B',
      source: 'chat',
      usage: const UsageTotals(input: 500, output: 200, cached: 100, requests: 2),
    ),
    UsageRecord(
      day: statisticsDay(DateTime(2026, 11, 5)),
      modelId: 'model-a',
      modelName: 'Model A',
      source: 'chat',
      usage: const UsageTotals(input: 100, output: 50, cached: 25, requests: 1),
    ),
    UsageRecord(
      day: statisticsDay(DateTime(2026, 11, 6)),
      modelId: 'model-a',
      modelName: 'Model A',
      source: 'suggestions',
      usage: const UsageTotals(input: 80, output: 20, cached: 40, requests: 1),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => I18n.apply(AppLang.zh));

  test('date filters, rankings, cache rate, and CSV use the same records', () {
    final stats = fixture();
    final recent = stats.period(30);
    expect(recent.totals.total, 250);
    expect(recent.totals.input, 180);
    expect(recent.totals.cached, 65);
    expect(recent.totals.cacheRate, closeTo(65 / 180, 0.0001));
    expect(recent.models.single.name, 'Model A');
    expect(recent.sources.map((e) => e.id), containsAll(['chat', 'suggestions']));
    expect(recent.daily.length, 30);
    expect(recent.activeDays, 2);
    expect(stats.period(7).totals.total, 250);
    expect(stats.period(90).totals.total, 950);
    expect(stats.period(null).totals.total, 950);
    final custom = stats.period(null, start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 1));
    expect(custom.totals.total, 700);
    expect(custom.daily.single.usage.total, 700);
    expect(custom.toCsv(), contains('2026-10-01,"chat"'), reason: 'CSV date is the first column');
  });

  for (final dark in [false, true]) {
    testWidgets('dashboard fits a narrow phone and filters the totals; dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? MewTheme.dark(0) : MewTheme.light(0),
          home: StatsPage(statistics: fixture()),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('聊天热力图'), findsOneWidget);
      expect(find.text('总消息数'), findsOneWidget);
      expect(find.text('应用启动次数'), findsOneWidget);
      expect(find.text('缓存命中率'), findsOneWidget);
      expect(find.text('36.1%'), findsOneWidget);
      await tester.ensureVisible(find.text('90 天'));
      await tester.tap(find.text('90 天'));
      await tester.pumpAndSettle();
      expect(find.text('680'), findsOneWidget);
      expect(find.text('950'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('按来源'));
      await tester.pumpAndSettle();
      expect(find.text('建议'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
