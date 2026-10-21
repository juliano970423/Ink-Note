import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';
import 'package:ink_notes/ui/eraser_icons.dart';
import 'package:ink_notes/ui/ink_canvas.dart';

Note _a4note() => Note(
      id: 'a1b2',
      title: 't',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      pageId: 'A4',
      strokes: [
        const Stroke(color: '#000000', size: 4.0, points: [
          NotePoint(x: 100, y: 100, p: 1.0, t: 0),
          NotePoint(x: 120, y: 120, p: 1.0, t: 10),
        ]),
      ],
    );

void main() {
  testWidgets('分頁條：新增頁 → 第2頁作畫歸屬正確 → 翻回第1頁', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 1/1 頁'), findsOneWidget);

    // 新增頁
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('第 2/2 頁'), findsOneWidget);

    // 在第 2 頁畫一筆（canvas 座標系內）
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    // tapAt 是點按：down+up 落下一筆單點筆
    expect(loaded.strokes.length, 2);
    expect(loaded.strokes.last.page, 1);

    // 翻回第 1 頁：畫布只剩原筆
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(find.text('第 1/2 頁'), findsOneWidget);
  });

  testWidgets('紙筆記頁面管理：下移換頁序，頁數不變', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    note.strokes.add(const Stroke(color: '#000000', size: 4.0, points: [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
      NotePoint(x: 120, y: 120, p: 1.0, t: 10),
    ], page: 1));
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    expect(find.text('頁面管理'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect([for (final s in loaded.strokes) s.page], [1, 0]);
    expect(find.text('第 2/2 頁'), findsOneWidget);
  });

  testWidgets('紙筆記頁面管理：插入空白頁把後頁筆跡往後推', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    note.strokes.add(const Stroke(color: '#000000', size: 4.0, points: [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
      NotePoint(x: 120, y: 120, p: 1.0, t: 10),
    ], page: 1));
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.note_add_outlined).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect([for (final s in loaded.strokes) s.page], [0, 2]);
    expect(find.text('第 2/3 頁'), findsOneWidget);
  });

  testWidgets('紙筆記頁面管理：刪頁掉筆跡、刪空白尾頁頁數回縮', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    note.strokes.add(const Stroke(color: '#000000', size: 4.0, points: [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
      NotePoint(x: 120, y: 120, p: 1.0, t: 10),
    ], page: 1));
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('第 3/3 頁'), findsOneWidget);
    await tester.tap(find.text('第 3/3 頁'));
    await tester.pumpAndSettle();
    expect(find.text('空白頁'), findsOneWidget);
    // 刪第 1 頁：該頁筆跡丟掉，第 2 頁筆跡前移，空白尾頁保留
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(loaded.strokes.length, 1);
    expect(loaded.strokes.single.page, 0);
    expect(find.text('第 1/2 頁'), findsOneWidget);
    // 再刪空白尾頁：頁數回縮到 1
    await tester.tap(find.byIcon(Icons.delete_outline).at(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第 1/1 頁'), findsOneWidget);
  });

  testWidgets('連續頁面：兩頁筆跡同屏堆疊，不切頁也都畫出來', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    note.strokes.add(const Stroke(color: '#000000', size: 4.0, points: [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
      NotePoint(x: 120, y: 120, p: 1.0, t: 10),
    ], page: 1));
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    // 快取重建是異步：等兩輪，堆疊繪製若崩會直接報錯
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(loaded.strokes.length, 2);
    expect(find.text('第 1/2 頁'), findsOneWidget);
    // 在第 1 頁可視區左側落筆仍歸第 0 頁（連續座標歸屬；避開底部中央分頁條）
    await tester.tapAt(const Offset(150, 500));
    await tester.pump();
    expect(loaded.strokes.last.page, 0);
  });

  testWidgets('兩段式撤銷：先回原軌跡，再消失', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    await store.save(note);
    // 起始清空，只留測試手畫的那筆
    final loaded = await store.load('a1b2');
    loaded.strokes.clear();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    // 手發原始事件：近似直線（帶抖動），收筆停 1.2s 再抬
    const pid = 1;
    tester.binding.handlePointerEvent(PointerDownEvent(
      pointer: pid,
      position: const Offset(300, 300),
      timeStamp: Duration.zero,
    ));
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      tester.binding.handlePointerEvent(PointerMoveEvent(
        pointer: pid,
        position: Offset(300 + i * 20, 300 + (i % 2) * 2.0),
        timeStamp: Duration(milliseconds: i * 50),
      ));
      await tester.pump();
    }
    tester.binding.handlePointerEvent(PointerUpEvent(
      pointer: pid,
      position: const Offset(500, 300),
      timeStamp: const Duration(milliseconds: 500 + 1200),
    ));
    await tester.pump();
    // 收筆停頓 → 拉直成 2 點
    expect(loaded.strokes.length, 1);
    expect(loaded.strokes.first.points.length, 2);
    // 第一段 undo：回到未修正的原軌跡（含插值共 51 點）
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(loaded.strokes.length, 1);
    expect(loaded.strokes.first.points.length, 51);
    // 第二段 undo：消失
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(loaded.strokes, isEmpty);
    // redo 回來的是原軌跡，再 redo 回到直線
    await tester.tap(find.byIcon(Icons.redo));
    await tester.pump();
    expect(loaded.strokes.first.points.length, 51);
    await tester.tap(find.byIcon(Icons.redo));
    await tester.pump();
    expect(loaded.strokes.first.points.length, 2);
  });

  for (final type in ['dashed', 'highlighter']) {
    testWidgets('$type 形狀修正：停頓拉直且保留筆型', (tester) async {
      final store = MemoryNoteStore();
      final note = _a4note();
      await store.save(note);
      final loaded = await store.load('a1b2');
      loaded.strokes.clear();
      final settings = AppSettings()..lastPenType = type;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorPage(repo: store, settings: settings, note: loaded),
        ),
      ));
      await tester.pumpAndSettle();

      const pid = 1;
      tester.binding.handlePointerEvent(PointerDownEvent(
        pointer: pid,
        position: const Offset(300, 300),
        timeStamp: Duration.zero,
      ));
      await tester.pump();
      for (var i = 1; i <= 10; i++) {
        tester.binding.handlePointerEvent(PointerMoveEvent(
          pointer: pid,
          position: Offset(300 + i * 20, 300 + (i % 2) * 2.0),
          timeStamp: Duration(milliseconds: i * 50),
        ));
        await tester.pump();
      }
      tester.binding.handlePointerEvent(PointerUpEvent(
        pointer: pid,
        position: const Offset(500, 300),
        timeStamp: const Duration(milliseconds: 500 + 1200),
      ));
      await tester.pump();

      expect(loaded.strokes.length, 1);
      expect(loaded.strokes.first.type, type);
      expect(loaded.strokes.first.points.length, 2);
      await tester.tap(find.byIcon(Icons.undo));
      await tester.pump();
      expect(loaded.strokes.first.points.length, 51);
    });
  }

  testWidgets('視圖模式：全屏回調 + 沉浸經三點菜單', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    await store.save(note);
    ViewMode? view;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store,
              settings: AppSettings(),
              note: await store.load('a1b2'),
              onViewChanged: (v) => view = v)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 1/1 頁'), findsOneWidget);

    // 全屏開關（回調外層收側欄；編輯器內頂欄保留）
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    expect(view, ViewMode.fullscreen);
    expect(find.text('第 1/1 頁'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    expect(view, ViewMode.normal);

    // 沉浸走三點菜單：頂欄+分頁條全藏，只剩恢復鈕
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('沉浸模式'));
    await tester.pumpAndSettle();
    expect(find.text('第 1/1 頁'), findsNothing);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(view, ViewMode.zen);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(find.text('第 1/1 頁'), findsOneWidget);
    expect(view, ViewMode.normal);
  });

  testWidgets('紙筆記頁面管理：圖片隨頁搬/刪，undo 還原；尾頁存檔', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    note.strokes.add(const Stroke(color: '#000000', size: 4.0, points: [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
      NotePoint(x: 120, y: 120, p: 1.0, t: 10),
    ], page: 1));
    note.images.add(const NoteImage(
        id: 'im1', page: 1, x: 100, y: 100, w: 40, h: 40));
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    // 第 2 頁上移：筆跡與圖片頁號一起搬
    await tester.tap(find.byIcon(Icons.arrow_upward).last);
    await tester.pump(const Duration(milliseconds: 300));
    expect([for (final s in loaded.strokes) s.page], [1, 0]);
    expect(loaded.images.single.page, 0);
    // 刪第 1 頁（有筆跡＋圖片）：一起丟
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect([for (final s in loaded.strokes) s.page], [0]);
    expect(loaded.images, isEmpty);
    // 關閉頁面管理 → undo：筆跡頁號與圖片都回來
    await tester.tapAt(const Offset(400, 60));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect([for (final s in loaded.strokes) s.page], [1, 0]);
    expect(loaded.images.single.page, 0);
  });

  testWidgets('紙筆記新增尾頁自動存檔，重開頁數不縮', (tester) async {
    final store = MemoryNoteStore();
    await store.save(_a4note());
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 1/1 頁'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.text('第 2/2 頁'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    final saved = await store.load('a1b2');
    expect(saved.extraPages, 1);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              key: UniqueKey(),
              repo: store, settings: AppSettings(), note: saved)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 1/2 頁'), findsOneWidget);
  });

  testWidgets('圈選操作條：第 2 頁用堆疊座標，不跑到畫面頂端', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    note.strokes.add(const Stroke(color: '#000000', size: 4.0, points: [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
      NotePoint(x: 120, y: 120, p: 1.0, t: 10),
    ], page: 1));
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 2 頁'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LassoIcon));
    await tester.pump();
    final g = await tester.startGesture(const Offset(70, 150));
    for (final p in const [
      Offset(230, 150),
      Offset(230, 220),
      Offset(70, 220),
      Offset(70, 150),
    ]) {
      await g.moveTo(p);
    }
    await g.up();
    await tester.pump();
    expect(find.byIcon(Icons.copy), findsOneWidget);
    final bar = tester.getTopLeft(find.byIcon(Icons.copy));
    // 舊算法用頁內座標：這條會 clamp 到 y≈8（蓋住工具欄）
    expect(bar.dy, greaterThan(60));
    expect(bar.dy, lessThan(250));
    expect(bar.dx, greaterThanOrEqualTo(8));
    expect(bar.dx, lessThan(700));
  });

  testWidgets('第 2 頁圈選拖曳：頁內座標正確，抬起才提交', (tester) async {
    final store = MemoryNoteStore();
    final note = _a4note();
    note.strokes.add(const Stroke(color: '#000000', size: 4.0, points: [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
      NotePoint(x: 120, y: 120, p: 1.0, t: 10),
    ], page: 1));
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: EditorPage(
              repo: store, settings: AppSettings(), note: loaded)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 2 頁'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LassoIcon));
    await tester.pump();
    final g = await tester.startGesture(const Offset(70, 150));
    for (final p in const [
      Offset(230, 150),
      Offset(230, 220),
      Offset(70, 220),
      Offset(70, 150),
    ]) {
      await g.moveTo(p);
    }
    await g.up();
    await tester.pump();
    expect(find.byIcon(Icons.copy), findsOneWidget);

    final canvas = tester.widget<InkCanvas>(find.byType(InkCanvas));
    final bounds = canvas.selectionBounds!.shift(Offset(
        0, canvas.pageRects[canvas.selectionPage].top - 24));
    final start =
        tester.getTopLeft(find.byType(InkCanvas)) +
            canvas.panOffset +
            (bounds.topLeft + const Offset(2, 2)) * canvas.scale;
    final before = loaded.strokes.last.points.first.x;
    final drag = await tester.startGesture(start);
    await drag.moveBy(Offset(40 * canvas.scale, 0));
    await tester.pump();
    expect(loaded.strokes.last.points.first.x, closeTo(before, 0.01));
    await drag.up();
    await tester.pump();
    expect(loaded.strokes.last.points.first.x, closeTo(before + 40, 1.0));
  });
}
