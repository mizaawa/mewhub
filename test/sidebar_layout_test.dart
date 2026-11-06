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
    var folderCreated = false;
    var sortByCreation = false;
    String? selectedFolder;
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
                folders: const [],
                selectedFolderId: null,
                sortByCreation: false,
                onNewFolder: () => folderCreated = true,
                onSelectFolder: (id) => selectedFolder = id,
                onRenameFolder: (_) {},
                onDeleteFolder: (_) {},
                onSortChanged: (created) => sortByCreation = created,
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
    await tester.tap(find.byKey(const ValueKey('sidebar-new-folder')));
    await tester.tap(find.byKey(const ValueKey('sidebar-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按创建时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-nav-settings')));

    expect(historyOpened, isTrue);
    expect(searchOpened, isTrue);
    expect(folderCreated, isTrue);
    expect(sortByCreation, isTrue);
    expect(selectedFolder, isNull);
    expect(destinations, contains('/settings'));
    expect(destinations, contains('/imagegen'));
    expect(destinations, contains('/translator'));
    expect(tester.takeException(), isNull);
  });
}
