import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/release_update.dart';
import 'package:mewhub/data/usage_statistics.dart';
import 'package:mewhub/ui/pages/usage_stats_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only a newer published GitHub release produces an update', () async {
    http.Client api(String tag, {int status = 200}) => MockClient(
      (_) async => http.Response(
        '{"tag_name":"$tag","body":"Fixes and improvements",'
        '"html_url":"https://github.com/mizaawa/mewhub/releases/tag/$tag"}',
        status,
      ),
    );

    final next = await checkForReleaseUpdate(client: api('v1.2.1'), currentVersion: '1.2.0');
    expect(next?.version, 'v1.2.1');
    expect(next?.notes, 'Fixes and improvements');
    expect(next?.url.path, '/mizaawa/mewhub/releases/tag/v1.2.1');
    expect(await checkForReleaseUpdate(client: api('v1.2.0'), currentVersion: '1.2.0'), isNull);
    expect(await checkForReleaseUpdate(client: api('v1.1.9'), currentVersion: '1.2.0'), isNull);
    expect(await checkForReleaseUpdate(client: api('v1.3.0', status: 403), currentVersion: '1.2.0'), isNull);
    expect(
      await checkForReleaseUpdate(client: MockClient((_) async => throw Exception('offline')), currentVersion: '1.2.0'),
      isNull,
    );
  });

  testWidgets('release notice is above Token usage and opens the published release', (tester) async {
    I18n.apply(AppLang.zh);
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final launches = <MethodCall>[];
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (call) async {
      launches.add(call);
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, null);
    });

    const notes = 'First\nSecond\nThird\nFourth\nFifth\nSixth';
    await tester.pumpWidget(
      MaterialApp(
        home: StatsPage(
          statistics: UsageStatistics(now: DateTime(2026, 11, 6)),
          releaseUpdate: Future.value(
            ReleaseUpdate(
              version: 'v1.3.0',
              notes: notes,
              url: Uri.parse('https://github.com/mizaawa/mewhub/releases/tag/v1.3.0'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('release-update-notice'));
    expect(card, findsOneWidget);
    expect(find.text('有新版本 v1.3.0'), findsOneWidget);
    final visibleNotes = tester.widget<Text>(
      find.byWidgetPredicate((widget) => widget is Text && (widget.data ?? '').startsWith('First')),
    );
    expect(visibleNotes.data, endsWith('......'));
    expect(visibleNotes.data, isNot(contains('Sixth')));
    expect(visibleNotes.maxLines, 5);
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump();
    expect(launches.where((call) => call.method == 'launch').length, 1);
    expect(launches.single.arguments.toString(), contains('/releases/tag/v1.3.0'));
  });
}
