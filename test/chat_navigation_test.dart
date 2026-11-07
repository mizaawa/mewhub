import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/ui/chat/chat_navigation.dart';

void main() {
  for (final reduceMotion in [false, true]) {
    testWidgets('compact tiles animate in 110ms and keep full touch targets; reduce=$reduceMotion', (tester) async {
      I18n.apply(AppLang.zh);
      final visible = ValueNotifier(false);
      addTearDown(visible.dispose);
      final taps = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: Center(
                child: ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (context, value, _) => ChatNavigation(
                    visible: value,
                    onTop: () => taps.add(0),
                    onPrevious: () => taps.add(1),
                    onNext: () => taps.add(2),
                    onBottom: () => taps.add(3),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final navigation = find.byKey(const ValueKey('chat-navigation'));
      final opacity = find.descendant(of: navigation, matching: find.byType(Opacity));
      expect(navigation, findsNothing);
      visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      if (!reduceMotion) {
        final first = tester.widget<Opacity>(opacity.first).opacity;
        final last = tester.widget<Opacity>(opacity.last).opacity;
        expect(first, inExclusiveRange(0, 1));
        expect(last, inExclusiveRange(0, first));
      }
      await tester.pump(const Duration(milliseconds: 78));
      for (final w in tester.widgetList<Opacity>(opacity)) {
        expect(w.opacity, 1);
      }
      final tiles = find.byWidgetPredicate((w) => w.key.toString().contains('jump-tile-'));
      expect(tiles, findsNWidgets(4));
      final targets = find.descendant(of: navigation, matching: find.byType(InkWell));
      expect(targets, findsNWidgets(4));
      for (var i = 0; i < 4; i++) {
        expect(tester.getSize(tiles.at(i)), const Size(24, 24));
        expect(tester.getSize(targets.at(i)), const Size(48, 48));
        // Hit the transparent padding, beyond the 24px visual tile.
        await tester.tapAt(tester.getCenter(targets.at(i)) + const Offset(20, 0));
      }
      expect(taps, [0, 1, 2, 3]);
      expect(tester.getRect(targets.at(1)).top - tester.getRect(targets.first).bottom, 4);
      visible.value = false;
      await tester.pump();
      if (!reduceMotion) {
        await tester.pump(const Duration(milliseconds: 45));
        final exiting = tester.widget<Opacity>(opacity.first).opacity;
        expect(exiting, inExclusiveRange(0, 1));
        // Rapidly resume: continue from the current frame, without snapping.
        visible.value = true;
        await tester.pump();
        expect(tester.widget<Opacity>(opacity.first).opacity, closeTo(exiting, 0.001));
        await tester.pump(const Duration(milliseconds: 110));
        expect(tester.widget<Opacity>(opacity.first).opacity, 1);
        visible.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(navigation, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
