import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/main.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';

void main() {
  testWidgets('App boots：窄屏 AppBar + 設置圖標 + 列表頭新筆記鈕（無 FAB/NavigationBar）',
      (tester) async {
    // 內存存儲（真實文件 IO 在 testWidgets 的 FakeAsync 區裡永遠等不到，
    // 文件行為由 note_repository_test 在真實異步區覆蓋）。
    final store = MemoryNoteStore();
    final settings = AppSettings();
    await tester.pumpWidget(InkNotesApp(repo: store, settings: settings));
    // 有限次 pump（不用 pumpAndSettle，會被 CircularProgressIndicator 卡住）：
    // 等到列表頭新筆記鈕出現為止
    for (var i = 0;
        i < 100 && find.text('新筆記').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Ink Notes'), findsWidgets);
    // MD3：單一頂級目的地不用 NavigationBar，設置走 AppBar 動作圖標
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    // 新筆記按鈕在列表頭（右下角只留新增頁，不打架）
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('新筆記'), findsOneWidget);
  });
}
