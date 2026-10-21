import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';
import 'package:ink_notes/ui/eraser_icons.dart';

Note _emptyNote() => Note(
      id: 'a1b2',
      title: 't',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      folder: '',
    );

Future<Note> _pumpEditor(WidgetTester tester) async {
  final store = MemoryNoteStore();
  await store.save(_emptyNote());
  final loaded = await store.load('a1b2');
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
    ),
  ));
  await tester.pumpAndSettle();
  return loaded;
}

Future<void> _openLayers(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.layers_outlined));
  await tester.pumpAndSettle();
}

Future<void> _closeLayers(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
  await tester.pumpAndSettle();
}

Future<void> _rowMenu(WidgetTester tester, String rowText) async {
  final row = find.ancestor(
    of: find.text(rowText),
    matching: find.byType(ListTile),
  );
  await tester.tap(find.descendant(
      of: row, matching: find.byType(PopupMenuButton<String>)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('新增圖層 → 新筆落到新層', (tester) async {
    final loaded = await _pumpEditor(tester);
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    expect(loaded.strokes.last.layer, 0);

    await _openLayers(tester);
    expect(find.text('圖層 1（使用中）'), findsOneWidget);
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    expect(find.text('圖層 2（使用中）'), findsOneWidget);
    await _closeLayers(tester);
    await tester.tapAt(const Offset(450, 450));
    await tester.pump();
    expect(loaded.strokes.last.layer, 1);
    expect(loaded.layerNames.length, 2);
  });

  testWidgets('隱藏圖層：橡皮擦不到隱藏筆', (tester) async {
    final loaded = await _pumpEditor(tester);
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await _openLayers(tester);
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    await _closeLayers(tester);
    await tester.pumpAndSettle();
    // 圖層 2 上落筆
    await tester.tapAt(const Offset(500, 500));
    await tester.pump();
    expect(loaded.strokes.last.layer, 1);

    // 隱藏圖層 2（列表第一行 = 最上層）
    await _openLayers(tester);
    await tester.tap(find.byIcon(Icons.visibility_outlined).first);
    await tester.pumpAndSettle();
    // 再把使用中層切到可見的圖層 1：隱藏層即使還是使用中也不該被擦到
    await tester.tap(find.text('圖層 1'));
    await tester.pumpAndSettle();
    await _closeLayers(tester);
    await tester.pumpAndSettle();

    // 按筆畫橡皮點兩筆：使用中可見層被擦，隱藏層還在
    await tester.tap(find.byType(StrokeEraserIcon));
    await tester.pump();
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await tester.tapAt(const Offset(500, 500));
    await tester.pump();
    expect(loaded.strokes.length, 1);
    expect(loaded.strokes.first.layer, 1);
  });

  testWidgets('使用中圖層隔離：按筆畫橡皮不擦別層', (tester) async {
    final loaded = await _pumpEditor(tester);
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await _openLayers(tester);
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    await _closeLayers(tester);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(500, 500));
    await tester.pump();
    expect(loaded.strokes.map((s) => s.layer).toList(), [0, 1]);

    // 使用中層 = 圖層 2；點兩筆只刪圖層 2
    await tester.tap(find.byType(StrokeEraserIcon));
    await tester.pump();
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await tester.tapAt(const Offset(500, 500));
    await tester.pump();
    expect(loaded.strokes.length, 1);
    expect(loaded.strokes.first.layer, 0);
  });

  testWidgets('使用中圖層隔離：圈選只圈使用中層', (tester) async {
    final loaded = await _pumpEditor(tester);
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await _openLayers(tester);
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    await _closeLayers(tester);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(500, 500));
    await tester.pump();
    expect(loaded.strokes.map((s) => s.layer).toList(), [0, 1]);

    // 使用中層 = 圖層 2；框住兩筆，操作條只處理圖層 2
    await tester.tap(find.byType(LassoIcon));
    await tester.pump();
    final g = await tester.startGesture(const Offset(380, 380));
    for (final p in const [
      Offset(520, 380),
      Offset(520, 520),
      Offset(380, 520),
      Offset(380, 380),
    ]) {
      await g.moveTo(p);
    }
    await g.up();
    await tester.pump();
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(loaded.strokes.length, 1);
    expect(loaded.strokes.first.layer, 0);
  });

  testWidgets('使用中圖層隔離：圖片只認使用中層', (tester) async {
    final store = MemoryNoteStore();
    final note = Note(
      id: 'a1b2',
      title: 't',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      folder: '',
      layerNames: ['下層', '上層'],
      images: const [
        NoteImage(
            id: 'im0', page: 0, x: 100, y: 100, w: 100, h: 100, layer: 0),
        NoteImage(
            id: 'im1', page: 0, x: 300, y: 300, w: 100, h: 100, layer: 1),
      ],
    );
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(LassoIcon));
    await tester.pump();
    Future<void> stylusTap(Offset p) async {
      final g = await tester.startGesture(p,
          kind: ui.PointerDeviceKind.stylus);
      await g.up();
      await tester.pump();
    }

    // 使用中層 = 上層；點下層圖片不選、不出操作條
    await stylusTap(const Offset(150, 150));
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(loaded.images.length, 2);

    // 點上層圖片才選中，刪除只掉上層
    await stylusTap(const Offset(350, 350));
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(loaded.images.length, 1);
    expect(loaded.images.single.layer, 0);
  });

  testWidgets('合併到下層 → 一層，撤銷回來', (tester) async {
    final loaded = await _pumpEditor(tester);
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await _openLayers(tester);
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    await _closeLayers(tester);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(500, 500));
    await tester.pump();
    expect(loaded.layerNames.length, 2);

    // 第一行（最上層）的 ⋯ → 合併到下層
    await _openLayers(tester);
    await _rowMenu(tester, '圖層 2（使用中）');
    await tester.tap(find.text('合併到下層'));
    await tester.pumpAndSettle();
    await _closeLayers(tester);
    await tester.pumpAndSettle();
    expect(loaded.layerNames.length, 1);
    expect(loaded.strokes.every((s) => s.layer == 0), isTrue);
    expect(loaded.strokes.length, 2);

    // 撤銷回兩層
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(loaded.layerNames.length, 2);
    expect(loaded.strokes.map((s) => s.layer).toSet(), {0, 1});
  });

  testWidgets('刪除圖層連筆一起刪，改名生效', (tester) async {
    final loaded = await _pumpEditor(tester);
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await _openLayers(tester);
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();

    // 改名
    await _rowMenu(tester, '圖層 2（使用中）');
    await tester.tap(find.text('重新命名'));
    await tester.pumpAndSettle();
    final dlg = find.ancestor(
      of: find.text('重新命名圖層'),
      matching: find.byType(AlertDialog),
    );
    await tester.enterText(
        find.descendant(of: dlg, matching: find.byType(TextField)), '線稿');
    await tester.tap(find.text('確定'));
    // 對話框退場動畫中輸入框還在閃，用定量 pump（pumpAndSettle 會等游標等到超時）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('線稿（使用中）'), findsOneWidget);

    // 刪除該層
    await _rowMenu(tester, '線稿（使用中）');
    await tester.tap(find.text('刪除該層（含筆跡）'));
    await tester.pumpAndSettle();
    await _closeLayers(tester);
    await tester.pumpAndSettle();
    expect(loaded.layerNames.length, 1);
    expect(loaded.strokes.length, 1);
  });
}
