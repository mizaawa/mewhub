import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/data/defaults.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/ui/chat/profile_header.dart';

void main() {
  test('new settings use the supplied image for the default assistant', () {
    expect(defaultAssistants().first.avatar, defaultAssistantAvatar);
    expect(defaultAssistants().first.name, 'MewBot');
    expect(AppSettings.initial().display.userName, 'Mew');
  });

  test('saved default cat avatar migrates while the assistant id stays stable', () {
    final oldAssistant = {...defaultAssistants().first.toJson(), 'avatar': '🐱'};
    final settings = AppSettings.fromJson({
      'assistants': [oldAssistant],
    });

    expect(settings.currentAssistant.id, defaultAssistantId);
    expect(settings.currentAssistant.avatar, defaultAssistantAvatar);
    expect(settings.currentAssistant.name, 'MewBot');

    final otherAssistant = {...oldAssistant, 'id': 'custom-assistant'};
    final otherSettings = AppSettings.fromJson({
      'assistants': [otherAssistant],
    });
    expect(otherSettings.currentAssistant.avatar, '🐱');
  });

  testWidgets('sidebar profile shows the saved name and opens its editor', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserProfileHeader(name: 'miza', avatar: '', onTap: () => tapped = true),
        ),
      ),
    );

    expect(find.text('miza'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.byKey(const ValueKey('user-profile-header')));
    expect(tapped, isTrue);
  });
}
