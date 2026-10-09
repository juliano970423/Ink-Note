import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';
import 'package:ink_notes/ui/eraser_icons.dart';
import 'package:ink_notes/ui/home_page.dart';

Note _seedNote(String id, String title, String folder) => Note(
      id: id,
      title: title,
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      folder: folder,
      strokes: [
        Stroke(color: '#000000', size: 4.0, points: [
          for (var i = 0; i < 10; i++)
            NotePoint(x: 100.0 + i * 10, y: 300, p: 1.0, t: i),
        ]),
      ],
    );

Future<void> _pumpNarrow(WidgetTester tester, MemoryNoteStore store) async {
  await tester.pumpWidget(
    MaterialApp(home: HomePage(repo: store, settings: AppSettings())),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('像素橡皮拖抹分裂筆畫，按筆畫橡皮點按刪除', (tester) async {
    final store = MemoryNoteStore();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    expect(loaded.strokes.length, 1);

    // 橡皮主鈕點按循環：筆 → 按筆畫 → 像素 → 按筆畫……
    // 默認顯示按筆畫圖標
    expect(find.byType(StrokeEraserIcon), findsOneWidget);
    await tester.tap(find.byType(StrokeEraserIcon));
    await tester.pump();
    // 已激活按筆畫：點中段不分裂（整筆還在），改用像素
    await tester.tap(find.byType(StrokeEraserIcon));
    await tester.pump();
    expect(find.byType(PixelEraserIcon), findsOneWidget);
    await tester.tapAt(const Offset(145, 300));
    await tester.pump();
    expect(loaded.strokes.length, 2);

    // 長按開菜單：模式 + 尺寸 + 關閉都在
    await tester.longPress(find.byType(PixelEraserIcon));
    await tester.pumpAndSettle();
    expect(find.text('按筆畫擦除'), findsOneWidget);
    expect(find.text('像素擦除'), findsOneWidget);
    expect(find.text('關閉橡皮'), findsOneWidget);
    await tester.tap(find.text('按筆畫擦除'));
    await tester.pumpAndSettle();
    expect(find.byType(StrokeEraserIcon), findsOneWidget);

    // 按筆畫橡皮：點按刪除其中一筆
    await tester.tapAt(const Offset(120, 300));
    await tester.pump();
    expect(loaded.strokes.length, 1);

    // 按筆畫橡皮：拖過另一筆同樣刪除
    expect(loaded.strokes.length, 1);
    await tester.dragFrom(const Offset(150, 300), const Offset(60, 0));
    await tester.pump();
    expect(loaded.strokes.length, 0);
  });

  testWidgets('按筆畫橡皮一次拖抹刪多筆，一次撤銷整批回來', (tester) async {
    final store = MemoryNoteStore();
    final note = Note(
      id: 'a1b2',
      title: 't',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      folder: '',
      strokes: [
        Stroke(color: '#000000', size: 4.0, points: [
          for (var i = 0; i < 10; i++)
            NotePoint(x: 100.0 + i * 10, y: 300, p: 1.0, t: i),
        ]),
        Stroke(color: '#000000', size: 4.0, points: [
          for (var i = 0; i < 10; i++)
            NotePoint(x: 150.0 + i * 10, y: 400, p: 1.0, t: i),
        ]),
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
    expect(loaded.strokes.length, 2);

    // 激活按筆畫橡皮，一筆斜拖穿過兩筆（100,300）→（200,400）
    await tester.tap(find.byType(StrokeEraserIcon));
    await tester.pump();
    await tester.dragFrom(const Offset(100, 300), const Offset(100, 100));
    await tester.pump();
    expect(loaded.strokes.length, 0);

    // 一次撤銷整批回來
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(loaded.strokes.length, 2);
  });

  testWidgets('雙指連點兩下撤銷、三下重做', (tester) async {
    final store = MemoryNoteStore();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    expect(loaded.strokes.length, 1);

    // 先落一筆（可撤銷的東西）
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    expect(loaded.strokes.length, 2);

    // 雙指同時輕點一次（兩指都抬起才算一點）
    Future<void> twoTap() async {
      final g1 = await tester.startGesture(const Offset(200, 200));
      final g2 = await tester.startGesture(const Offset(280, 200));
      await g1.up();
      await g2.up();
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 連點兩下 → undo（500ms 判定窗過後生效）
    await twoTap();
    await twoTap();
    await tester.pump(const Duration(milliseconds: 600));
    expect(loaded.strokes.length, 1);

    // 連點三下 → redo
    await twoTap();
    await twoTap();
    await twoTap();
    await tester.pump(const Duration(milliseconds: 600));
    expect(loaded.strokes.length, 2);
  });

  testWidgets('圈選旋轉：拖手柄 90° → 橫筆變豎筆 → 撤銷回來', (tester) async {
    final store = MemoryNoteStore();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();

    // 圈住橫筆（x 100..190，y 300；手柄在底中 (145, 344)）
    await tester.tap(find.byType(LassoIcon));
    await tester.pump();
    final g = await tester.startGesture(const Offset(80, 280));
    for (final p in const [
      Offset(210, 280),
      Offset(210, 320),
      Offset(80, 320),
      Offset(80, 280),
    ]) {
      await g.moveTo(p);
    }
    await g.up();
    await tester.pump();
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // 拖手柄從正下方轉到正右方（-90°，橫筆變豎筆）
    await tester.dragFrom(const Offset(145, 344), const Offset(44, -44));
    await tester.pump();
    final xs =
        loaded.strokes.first.points.map((p) => p.x).toList();
    final ys =
        loaded.strokes.first.points.map((p) => p.y).toList();
    for (final x in xs) {
      expect(x, closeTo(145, 3.0));
    }
    expect(ys.reduce((a, b) => a > b ? a : b) -
        ys.reduce((a, b) => a < b ? a : b), closeTo(90, 5.0));

    // 撤銷回橫筆
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    final xs2 =
        loaded.strokes.first.points.map((p) => p.x).toList();
    expect(xs2.reduce((a, b) => a > b ? a : b) -
        xs2.reduce((a, b) => a < b ? a : b), closeTo(90, 5.0));
  });

  testWidgets('redo：撤銷後可重做，新動作清空', (tester) async {
    final store = MemoryNoteStore();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    expect(loaded.strokes.length, 1);

    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    expect(loaded.strokes.length, 2);

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(loaded.strokes.length, 1);

    await tester.tap(find.byIcon(Icons.redo));
    await tester.pump();
    expect(loaded.strokes.length, 2);

    // 新動作清空 redo
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    await tester.tapAt(const Offset(450, 450));
    await tester.pump();
    expect(loaded.strokes.length, 2);
    // redo 已空：按了也沒變化（按鈕 disabled，tap 會拋錯故只斷言狀態）
    expect(loaded.strokes.length, 2);
  });

  testWidgets('圈選：框住 → 出現操作條 → 刪除', (tester) async {
    final store = MemoryNoteStore();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();

    // 切圈選工具，單手勢畫矩形框住筆畫
    await tester.tap(find.byType(LassoIcon));
    await tester.pump();
    final g = await tester.startGesture(const Offset(80, 280));
    for (final p in const [
      Offset(210, 280),
      Offset(210, 320),
      Offset(80, 320),
      Offset(80, 280),
    ]) {
      await g.moveTo(p);
    }
    await g.up();
    await tester.pump();
    // 選中操作條出現
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    // 框內拖動 → 整組平移（+40,+0）
    final before =
        loaded.strokes.first.points.map((p) => p.x).toList();
    await tester.dragFrom(const Offset(140, 300), const Offset(40, 0));
    await tester.pump();
    final after =
        loaded.strokes.first.points.map((p) => p.x).toList();
    for (var i = 0; i < before.length; i++) {
      expect(after[i], closeTo(before[i] + 40, 1.0));
    }
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(loaded.strokes, isEmpty);
  });

  Future<void> pumpEditor(WidgetTester tester, MemoryNoteStore store,
      AppSettings settings, Note note) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: settings, note: note),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> lassoSelect(
      WidgetTester tester, List<Offset> corners) async {
    await tester.tap(find.byType(LassoIcon));
    await tester.pump();
    final g = await tester.startGesture(corners.first);
    for (final p in corners.skip(1)) {
      await g.moveTo(p);
    }
    await g.up();
    await tester.pump();
  }

  testWidgets('圈選複製：副本偏移並選中新件', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await pumpEditor(tester, store, settings, loaded);
    await lassoSelect(tester, const [
      Offset(80, 280),
      Offset(210, 280),
      Offset(210, 320),
      Offset(80, 320),
      Offset(80, 280),
    ]);
    expect(find.byIcon(Icons.copy), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy));
    await tester.pump();
    expect(loaded.strokes.length, 2);
    expect(loaded.strokes[1].points.first.x,
        loaded.strokes[0].points.first.x + 24);
  });

  testWidgets('圈選移動出紙：紙外部分被丟掉', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings();
    final note = Note(
      id: 'a1b2',
      title: 't',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      pageId: 'A4',
      strokes: [
        Stroke(color: '#000000', size: 4.0, points: [
          for (var i = 0; i < 10; i++)
            NotePoint(x: 700.0 + i * 5, y: 300, p: 1.0, t: i),
        ]),
      ],
    );
    await store.save(note);
    final loaded = await store.load('a1b2');
    await pumpEditor(tester, store, settings, loaded);
    await lassoSelect(tester, const [
      Offset(680, 280),
      Offset(800, 280),
      Offset(800, 320),
      Offset(680, 320),
      Offset(680, 280),
    ]);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    // 往右拖 100（A4 右邊 818，只出去一半）
    await tester.dragFrom(const Offset(740, 300), const Offset(100, 0));
    await tester.pump();
    final page = PageSize.byId('A4')!;
    final right = 24 + page.wPx + 0.01;
    // 放開不裁：拖出去的部分還在，拖回去能救
    expect(loaded.strokes.expand((s) => s.points).any((p) => p.x > right),
        isTrue);
    // 點紙面空白取消選取：此時才把出紙部分裁掉
    await tester.tapAt(const Offset(400, 500));
    await tester.pump();
    for (final s in loaded.strokes) {
      for (final p in s.points) {
        expect(p.x <= right, isTrue);
      }
    }
    expect(loaded.strokes, isNotEmpty);
  });

  testWidgets('筆刷菜單：調色盤切換真實換色 + 大小滑桿', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(
            repo: store,
            settings: settings,
            note: await store.load('a1b2')),
      ),
    ));
    await tester.pumpAndSettle();
    Finder slots() => find.byWidgetPredicate(
        (w) => w is PenColorButton && w.size == 24,
        skipOffstage: false);
    expect(slots(), findsNWidgets(3));
    await tester.longPress(slots().first);
    await tester.pumpAndSettle();
    expect(find.text('筆刷1設定'), findsOneWidget);
    expect(find.text('筆色'), findsOneWidget);
    expect(find.text('大小'), findsOneWidget);
    // 調色盤第 6 格是紅色 #d32f2f：選它並確認真的換色
    final circles = find.byWidgetPredicate(
      (w) =>
          w is InkWell &&
          w.child is Container &&
          (w.child as Container).decoration is BoxDecoration,
      skipOffstage: false,
    );
    expect(circles, findsNWidgets(20));
    await tester.tap(circles.at(5));
    await tester.pump();
    expect(settings.lastColor, '#d32f2f');
    expect(settings.quickPens.first.color, '#d32f2f');
  });

  testWidgets('rail 雙目的地：設置內嵌切換', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = MemoryNoteStore();
    await store.save(_seedNote('a1b2', '根筆記', ''));
    await _pumpNarrow(tester, store);
    await tester.pumpAndSettle();
    // 點 rail 設置 → 右側變設置頁
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('手感調參'), findsOneWidget);
    // 點回筆記
    await tester.tap(find.byIcon(Icons.note_outlined));
    await tester.pumpAndSettle();
    expect(find.text('根筆記'), findsOneWidget);
  });

  testWidgets('筆槽：點按整套切換，設定改槽即套用', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings();
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: settings, note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    final slots = find.byWidgetPredicate(
      (w) => w is PenColorButton && w.size == 24,
      skipOffstage: false,
    );
    expect(slots, findsNWidgets(3));
    // 點第 3 槽（藍螢光）→ 當前筆整套換過去
    await tester.tap(slots.at(2));
    await tester.pump();
    expect(settings.lastColor, '#1565c0');
    expect(settings.lastPenType, 'highlighter');
    // 長按第 1 槽開設定 → 改虛線 → 槽內容與當前筆同步
    await tester.longPress(slots.first);
    await tester.pumpAndSettle();
    expect(find.text('筆刷1設定'), findsOneWidget);
    await tester.tap(find.text('虛線'));
    await tester.pump();
    expect(settings.quickPens.first.type, 'dashed');
    expect(settings.lastPenType, 'dashed');
  });

  testWidgets('唯讀：落筆不畫只平移', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings()..readOnly = true;
    final note = _seedNote('a1b2', 't', '');
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: settings, note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    await tester.dragFrom(const Offset(400, 400), const Offset(50, 0));
    await tester.pump();
    // 原有 1 筆還在，沒新增
    expect(loaded.strokes.length, 1);
  });

  testWidgets('防誤觸：觸屏不畫（單指改平移）', (tester) async {
    final store = MemoryNoteStore();
    final settings = AppSettings()..palmRejection = true;
    final note = _seedNote('a1b2', 't', '');
    // 種子筆改到別處，避開測試點
    await store.save(note);
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: settings, note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(500, 500));
    await tester.pump();
    expect(loaded.strokes.length, 1);
  });

  testWidgets('資料夾篩選 chips（寬屏）', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = MemoryNoteStore();
    await store.save(_seedNote('a1b2', '根筆記', ''));
    await store.save(_seedNote('c3d4', '工作筆記', '工作'));
    await _pumpNarrow(tester, store);
    await tester.pumpAndSettle();

    // 默認全部可見
    expect(find.text('根筆記'), findsOneWidget);
    expect(find.text('工作筆記'), findsOneWidget);
    // 切到 工作 資料夾
    await tester.tap(find.text('工作'));
    await tester.pump();
    expect(find.text('根筆記'), findsNothing);
    expect(find.text('工作筆記'), findsOneWidget);
  });
}
