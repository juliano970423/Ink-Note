import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';

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
}
