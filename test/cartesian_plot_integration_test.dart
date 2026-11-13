import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/tools/local_tools.dart';
import 'package:mewhub/ui/assistant/assistant_edit_page.dart';
import 'package:mewhub/ui/chat/tool_card.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/cartesian_plot_view.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => I18n.apply(AppLang.zh));

  test('plotting is opt-in and survives assistant JSON round trips', () {
    final original = Assistant(id: 'math', localTools: const {});
    expect(buildLocalTools(original.localTools).any((tool) => tool.name == 'plot_cartesian'), isFalse);
    final enabled = original.copyWith(localTools: {LocalTool.timeInfo, LocalTool.cartesianPlot});
    final restored = Assistant.fromJson(jsonDecode(jsonEncode(enabled.toJson())) as Map<String, dynamic>);
    expect(buildLocalTools(restored.localTools).map((tool) => tool.name), contains('plot_cartesian'));
    expect(Assistant.fromJson({'id': 'old'}).localTools, {LocalTool.timeInfo});
  });

  testWidgets('assistant local-tools switch persists the coordinate feature', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _PlotStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsStore>.value(
        value: store,
        child: MaterialApp(
          theme: MewTheme.light(0),
          home: const AssistantEditPage(assistantId: 'math'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('工具'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('平面直角坐标系显示'), 220, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('平面直角坐标系显示'));
    await tester.pumpAndSettle();
    expect(store.value.assistantById('math')!.localTools, contains(LocalTool.cartesianPlot));
    expect(tester.takeException(), isNull);
  });

  testWidgets('executed plot tools render from saved messages and open full screen', (tester) async {
    final tool = buildLocalTools({LocalTool.cartesianPlot}).single;
    final output = await tool.execute({
      'title': '抛物线',
      'functions': ['x^2'],
      'points': [
        {'x': 1, 'y': 1, 'label': 'A'},
      ],
    });
    final original = ToolPart(callId: 'plot', name: tool.name, input: '{}', output: output);
    final restored = Part.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>)! as ToolPart;
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: SingleChildScrollView(child: ToolCard(part: restored)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CartesianPlotCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending, denied and malformed plot results never render a graph', (tester) async {
    for (final part in [
      const ToolPart(callId: 'p', name: 'plot_cartesian', input: '{}', approval: ToolApproval.pending),
      const ToolPart(callId: 'p', name: 'plot_cartesian', input: '{}', output: '{broken'),
      const ToolPart(callId: 'p', name: 'plot_cartesian', input: '{}', output: '{"error":"invalid range"}'),
      const ToolPart(
        callId: 'p',
        name: 'plot_cartesian',
        input: '{}',
        output: '{"type":"cartesian_plot","plot":{}}',
        approval: ToolApproval.denied,
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ToolCard(part: part)),
        ),
      );
      await tester.pump();
      expect(find.byType(CartesianPlotCard), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}

class _PlotStore extends ChangeNotifier implements SettingsStore {
  AppSettings _value = AppSettings.initial().copyWith(
    assistants: [Assistant(id: 'math', name: '数学助手', localTools: const {})],
    currentAssistantId: 'math',
  );

  @override
  AppSettings get value => _value;

  @override
  void upsertAssistant(Assistant a) {
    _value = _value.copyWith(assistants: [a]);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
