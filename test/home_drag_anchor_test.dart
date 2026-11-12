// 首頁長按拖曳的 feedback pill 錨點（回歸測試）。
// 修前：LongPressDraggable 預設 childDragAnchorStrategy 把「卡片上按住的點」
// 當 feedback 錨——pill 比卡片小得多時，pill 固定飄在手指左上一段距離。
// 修後：pointerDragAnchorStrategy（feedback 左上角在指針）＋
// FractionalTranslation(-0.5, -1.2) 讓 pill 懸在指尖上方。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/main.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';

void main() {
  testWidgets('拖曳 pill 以指針為錨並上浮：Positioned 在手指位置、translation=(-0.5,-1.2)',
      (tester) async {
    final store = MemoryNoteStore();
    await store.save(Note(
      id: 'n1',
      title: '拖曳筆記',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    ));
    await tester.pumpWidget(InkNotesApp(repo: store, settings: AppSettings()));
    for (var i = 0;
        i < 100 && find.text('拖曳筆記').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final down = tester.getCenter(find.text('拖曳筆記').first);
    final g = await tester.startGesture(down);
    await tester.pump(const Duration(milliseconds: 500)); // 350ms 長按拾起
    const move = Offset(40, 30);
    await g.moveBy(move);
    await tester.pump();

    const anchor = Offset(-0.5, -1.2);
    final pill = find.byWidgetPredicate(
        (w) => w is FractionalTranslation && w.translation == anchor);
    expect(pill, findsOneWidget);
    final pos = tester.widget<Positioned>(
        find.ancestor(of: pill, matching: find.byType(Positioned)).first);
    // pointerDragAnchorStrategy：feedback 左上角＝指針（dragStartPoint=0）
    expect(pos.left, closeTo(down.dx + move.dx, 0.5));
    expect(pos.top, closeTo(down.dy + move.dy, 0.5));

    await g.up();
    await tester.pump();
  });
}
