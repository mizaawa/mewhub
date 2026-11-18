import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/app.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:provider/provider.dart';

class _Settings extends ChangeNotifier implements SettingsStore {
  _Settings(ThemeModePref mode) : value = AppSettings.fromJson(const {}).copyWith(themeMode: mode);
  @override
  final AppSettings value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final mode in [ThemeModePref.dark, ThemeModePref.system]) {
    testWidgets('dark push and pop never expose the bright host (mode: $mode)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      tester.platformDispatcher.platformBrightnessTestValue = mode == ThemeModePref.dark
          ? Brightness.light
          : Brightness.dark;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final store = _Settings(mode);
      addTearDown(store.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ColoredBox(
            color: Colors.white,
            child: ChangeNotifierProvider<SettingsStore>.value(value: store, child: const MewHubApp()),
          ),
        ),
      );
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      MaterialPageRoute<void> page() => MaterialPageRoute<void>(builder: (_) => const Scaffold());
      unawaited(nav.pushReplacement(page()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      final surface = Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor;
      expect(surface.computeLuminance(), lessThan(.03));

      // Sample actual composite pixels, not just the final route or its declared theme.
      Future<void> checkTransition(String direction, Duration duration) async {
        for (var frame = 0; frame * 16 <= duration.inMilliseconds; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final colors = (await tester.runAsync(() async {
            final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: .1);
            try {
              final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
              return [
                for (final x in [1, image.width ~/ 2, image.width - 2])
                  for (final y in [1, image.height ~/ 2, image.height - 2])
                    Color(0xff000000 | (data.getUint32((y * image.width + x) * 4) >> 8)),
              ];
            } finally {
              image.dispose();
            }
          }))!;
          for (final color in colors) {
            expect(
              color.computeLuminance(),
              lessThan(surface.computeLuminance() + .015),
              reason: '$direction frame $frame: $color over $surface',
            );
          }
        }
        await tester.pumpAndSettle();
      }

      final next = page();
      unawaited(nav.push(next));
      await tester.pump();
      await checkTransition('push', next.transitionDuration);
      nav.pop();
      await tester.pump();
      await checkTransition('pop', next.reverseTransitionDuration);
    }, variant: TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
  }
}
