import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';
import 'package:ink_notes/ui/eraser_icons.dart';

Note _note() => Note(
      id: 'a1b2',
      title: 't',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
    );

Finder _slots() => find.byWidgetPredicate(
      (w) => w is PenColorButton && w.size == 24,
      skipOffstage: false,
    );

/// 筆槽制：三支筆各帶設定；長按開槽設定，改完立即套用。
void main() {
  testWidgets('筆槽設定：改筆型落筆帶 type', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings();
    final note = _note();
    await store.save(note);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(repo: store, settings: settings, note: note)),
    ));
    await tester.pumpAndSettle();
    expect(_slots(), findsNWidgets(3));

    // 長按第 1 槽開設定 → 切螢光
    await tester.longPress(_slots().first);
    await tester.pumpAndSettle();
    expect(find.text('筆刷1設定'), findsOneWidget);
    await tester.tap(find.text('螢光'));
    await tester.pump();
    expect(settings.lastPenType, 'highlighter');
    expect(settings.quickPens.first.type, 'highlighter');
    // 點空白關菜單（順手落個螢光點）
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    expect(note.strokes.length, 2);
    expect(note.strokes.every((s) => s.type == 'highlighter'), isTrue);
  });
}
