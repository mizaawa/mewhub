import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/assistant/assistant_edit_page.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every tool switch explains itself in one line of small text', (tester) async {
    I18n.apply(AppLang.zh);
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _ToolsStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsStore>.value(
        value: store,
        child: MaterialApp(
          theme: MewTheme.light(0),
          home: const AssistantEditPage(assistantId: 'helper'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('工具'));
    await tester.pumpAndSettle();

    const localTools = ['时间日期', '计算器', '平面直角坐标系显示', '剪贴板（需确认）', '设备信息'];
    final heights = <double>{};
    for (final title in ['运行工具前询问', ...localTools]) {
      final tileFinder = find.ancestor(of: find.text(title), matching: find.byType(SwitchListTile));
      final subtitle = tester.widget<SwitchListTile>(tileFinder).subtitle;
      expect(subtitle, isA<Text>(), reason: '$title needs a subtitle');
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: tileFinder, matching: find.text((subtitle! as Text).data!)),
      );
      // The natural width fits the laid-out width, so the note stays on one line.
      expect(paragraph.getMaxIntrinsicWidth(double.infinity), lessThanOrEqualTo(paragraph.size.width), reason: title);
      if (localTools.contains(title)) heights.add(tester.getSize(tileFinder).height);
    }
    expect(heights, hasLength(1), reason: 'local tool rows share one height');
    expect(tester.takeException(), isNull);
  });
}

class _ToolsStore extends ChangeNotifier implements SettingsStore {
  @override
  final AppSettings value = AppSettings.initial().copyWith(
    assistants: [Assistant(id: 'helper', name: 'Helper')],
    currentAssistantId: 'helper',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
