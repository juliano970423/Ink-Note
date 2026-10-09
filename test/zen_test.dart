import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';
import 'package:ink_notes/ui/home_page.dart';

/// 寬屏視圖聯動：
/// 全屏 → rail+列表收（頂欄留）；沉浸（經三點菜單）→ 全收只剩恢復鈕；恢復 → 全回來。
void main() {
  testWidgets('wide views：全屏/沉浸聯動收起並恢復', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: HomePage(repo: MemoryNoteStore(), settings: AppSettings())));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('新筆記'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('無限畫布'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorPage), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);

    // 全屏：側欄收，頂欄留
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('新筆記'), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    expect(find.byType(NavigationRail), findsOneWidget);

    // 全屏下進沉浸：恢復要回到全屏（記住原本樣子）
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('沉浸模式'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('新筆記'), findsNothing);
    expect(find.byIcon(Icons.visibility), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();
    // 回到全屏而非普通（rail 仍收著，但頂欄回來了）
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
  });
}
