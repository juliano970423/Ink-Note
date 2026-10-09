import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';
import 'package:ink_notes/ui/eraser_icons.dart';
import 'package:ink_notes/ui/home_page.dart';

/// 端到端（無頭）：列表頭新筆記鈕 → 選 A4 → 建檔進編輯器 → 畫布/工具欄存在。
void main() {
  testWidgets('create flow：選尺寸 → 建檔 → 編輯器', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings();
    await tester.pumpWidget(
      MaterialApp(home: HomePage(repo: store, settings: settings)),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('新筆記'));
    await tester.pumpAndSettle();
    expect(find.text('新筆記：頁面尺寸'), findsOneWidget);

    await tester.tap(find.textContaining('A4'));
    await tester.pumpAndSettle();

    // 進了編輯器（窄屏 push 新路由）
    expect(find.byType(EditorPage), findsOneWidget);
    final notes = await store.listAll();
    expect(notes.length, 1);
    expect(notes.first.pageId, 'A4');
    // 工具欄：三筆槽 / 橡皮單鈕 / 圈選 / 全屏 / 更多 / 匯出 / 重做
    expect(find.byType(PenColorButton), findsNWidgets(3));
    expect(find.byType(StrokeEraserIcon), findsOneWidget);
    expect(find.byType(LassoIcon), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    expect(find.byIcon(Icons.redo), findsOneWidget);
    // 橡皮長按開菜單：兩種模式 + 關閉都在
    await tester.longPress(find.byType(StrokeEraserIcon));
    await tester.pumpAndSettle();
    expect(find.text('按筆畫擦除'), findsOneWidget);
    expect(find.text('像素擦除'), findsOneWidget);
    expect(find.text('關閉橡皮'), findsOneWidget);
  });
}
