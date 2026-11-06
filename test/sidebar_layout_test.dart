import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ui/chat/sidebar_widgets.dart';

void main() {
  testWidgets('sidebar shortcuts and chat toolbar expose the RikkaHub-style actions', (tester) async {
    tester.view.physicalSize = const Size(316, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var historyOpened = false;
    var searchOpened = false;
    var newChatCreated = false;
    var assistantsToggled = false;
    var sortToggled = false;
    final destinations = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SidebarQuickLinks(
                searchOpen: false,
                onHistory: () => historyOpened = true,
                onSearch: () => searchOpened = true,
                onImages: () => destinations.add('/imagegen'),
                onTranslate: () => destinations.add('/translator'),
              ),
              SidebarChatToolbar(
                allAssistants: false,
                sortByTitle: false,
                onNewChat: () => newChatCreated = true,
                onToggleAssistants: () => assistantsToggled = true,
                onToggleSort: () => sortToggled = true,
              ),
              SidebarBottomActions(onNavigate: destinations.add),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('sidebar-history')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-media')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-translate')), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-chat-tab')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sidebar-history')));
    await tester.tap(find.byKey(const ValueKey('sidebar-history-search')));
    await tester.tap(find.byKey(const ValueKey('sidebar-media')));
    await tester.tap(find.byKey(const ValueKey('sidebar-translate')));
    await tester.tap(find.byKey(const ValueKey('sidebar-new-chat')));
    await tester.tap(find.byKey(const ValueKey('sidebar-assistant-filter')));
    await tester.tap(find.byKey(const ValueKey('sidebar-sort')));
    await tester.tap(find.byKey(const ValueKey('sidebar-nav-settings')));

    expect(historyOpened, isTrue);
    expect(searchOpened, isTrue);
    expect(newChatCreated, isTrue);
    expect(assistantsToggled, isTrue);
    expect(sortToggled, isTrue);
    expect(destinations, contains('/settings'));
    expect(destinations, contains('/imagegen'));
    expect(destinations, contains('/translator'));
    expect(tester.takeException(), isNull);
  });
}
