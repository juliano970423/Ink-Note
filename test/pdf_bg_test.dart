import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/export/note_pdf.dart';
import 'package:ink_notes/import/pdf_import.dart';
import 'package:ink_notes/import/pdf_vector.dart';
import 'package:ink_notes/ink/stroke_renderer.dart';
import 'package:ink_notes/ink/velocity_tracker.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/storage/memory_note_store.dart';
import 'package:ink_notes/ui/editor_page.dart';
import 'package:ink_notes/ui/ink_canvas.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart' as pdoc;

Future<Uint8List> _solidPng(int argb) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 100, 140),
    ui.Paint()..color = ui.Color(argb),
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(100, 140);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  pic.dispose();
  img.dispose();
  return d!.buffer.asUint8List();
}

Note _bgNote() => Note(
      id: 'a1b2',
      title: 'pdf',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      folder: '',
      backgrounds: const [PageBg(w: 100, h: 140, key: 'k0', src: 0)],
    );

void main() {
  test('BG roundtrip + delete cleanup', () async {
    final store = MemoryNoteStore();
    await store.save(_bgNote());
    final png = await _solidPng(0xFFFFFFFF);
    await store.saveBackground('a1b2', 'k0', png);
    final back = await store.loadBackground('a1b2', 'k0');
    expect(back, isNotNull);
    expect(back!.length, png.length);
    expect(await store.loadBackground('a1b2', 'nope'), isNull);
    await store.delete('a1b2');
    expect(await store.loadBackground('a1b2', 'k0'), isNull);
  });

  // 注意：本機 flutter_tester 的 FakeAsync 里 toImage/圖片解碼會掛起，
  // 所以 widget 測試只用無字節底圖（版式/歸屬/分頁條/不崩），
  // 真實解碼走純 test（上）與瀏覽器實測。
  testWidgets('BG note no bytes: layout ok, stroke page 0', (tester) async {
    final store = MemoryNoteStore();
    await store.save(_bgNote());
    final loaded = await store.load('a1b2');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(400, 400));
    await tester.pump();
    expect(loaded.strokes.length, 1);
    expect(loaded.strokes.first.page, 0);
    // 底圖筆記也有分頁條（1 頁）
    expect(find.text('第 1/1 頁'), findsOneWidget);
  });

  test('legacy bg gets stable key + overflow pages backfilled', () {
    final note = Note.fromJson({
      'id': 'a1b2',
      'title': 't',
      'createdAt': '2026-10-05T00:00:00.000Z',
      'updatedAt': '2026-10-05T00:00:00.000Z',
      'backgrounds': [
        {'w': 100, 'h': 140},
      ],
      'strokes': [
        {
          'color': '#000000',
          'size': 4.0,
          'points': [
            {'x': 10, 'y': 10, 'p': 1, 't': 0},
          ],
          'page': 2,
        },
      ],
    });
    // 舊條目補穩定鍵 p0；第 1、2 頁補空白頁（鍵 x1、x2，尺寸套末頁）
    expect(note.backgrounds.length, 3);
    expect(note.backgrounds[0].key, 'p0');
    expect(note.backgrounds[1].key, 'x1');
    expect(note.backgrounds[2].key, 'x2');
    expect(note.backgrounds[1].src, isNull);
    expect(note.backgrounds[2].w, 100);
    // 存檔再讀鍵穩定
    final again = Note.decode(note.encode());
    expect([for (final b in again.backgrounds) b.key], ['p0', 'x1', 'x2']);
  });

  test('BG note raster export valid PDF', () async {
    final store = MemoryNoteStore();
    final note = _bgNote();
    note.strokes.add(const Stroke(
      color: '#000000',
      size: 4.0,
      points: [
        NotePoint(x: 100, y: 100, p: 1, t: 0),
        NotePoint(x: 200, y: 100, p: 1, t: 10),
      ],
    ));
    await store.save(note);
    final png = await _solidPng(0xFFFFFFFF);
    final bytes = await buildNotePdf(note, backgrounds: {0: png});
    final head = String.fromCharCodes(bytes.take(5));
    expect(head, '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  Note twoBgNote() => Note(
        id: 'c3d4',
        title: 'pdf2',
        createdAt: DateTime.utc(2026, 10, 5),
        updatedAt: DateTime.utc(2026, 10, 5),
        folder: '',
        backgrounds: const [
          PageBg(w: 100, h: 140, key: 'k0', src: 0),
          PageBg(w: 100, h: 140, key: 'k1', src: 1),
        ],
        strokes: [
          const Stroke(color: '#000000', size: 4.0, points: [
            NotePoint(x: 100, y: 100, p: 1, t: 0),
            NotePoint(x: 200, y: 100, p: 1, t: 10),
          ]),
        ],
      );

  testWidgets('pagination + appends real blank page', (tester) async {
    final store = MemoryNoteStore();
    await store.save(twoBgNote());
    final loaded = await store.load('c3d4');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('第 1/2 頁'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump(const Duration(milliseconds: 300));
    expect(loaded.backgrounds.length, 3);
    expect(loaded.backgrounds.last.src, isNull);
    expect(loaded.backgrounds.last.key, isNotEmpty);
    expect(find.text('第 3/3 頁'), findsOneWidget);
  });

  testWidgets('page manager: move down reorders + strokes follow',
      (tester) async {
    final store = MemoryNoteStore();
    await store.save(twoBgNote());
    final loaded = await store.load('c3d4');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    expect(find.text('頁面管理'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect([for (final b in loaded.backgrounds) b.key], ['k1', 'k0']);
    expect(loaded.strokes.single.page, 1);
  });

  testWidgets('page manager: insert blank below row', (tester) async {
    final store = MemoryNoteStore();
    await store.save(twoBgNote());
    final loaded = await store.load('c3d4');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.note_add_outlined).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(loaded.backgrounds.length, 3);
    expect(loaded.backgrounds[1].src, isNull);
    expect(loaded.strokes.single.page, 0);
  });

  testWidgets('page manager: delete drops strokes, keeps >= 1 page',
      (tester) async {
    final store = MemoryNoteStore();
    await store.save(twoBgNote());
    final loaded = await store.load('c3d4');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(repo: store, settings: AppSettings(), note: loaded),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1/2 頁'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(loaded.backgrounds.length, 1);
    expect(loaded.backgrounds.single.key, 'k1');
    expect(loaded.strokes, isEmpty);
  });

  test('bgUpgradeWidth: 檔位數學', () {
    // scale1 dpr1 → 需要 800：已解碼 1600 夠用
    expect(bgUpgradeWidth(scale: 1, dpr: 1, decoded: 1600), isNull);
    // scale2 dpr1 → 需要 1600：2400 夠
    expect(bgUpgradeWidth(scale: 2, dpr: 1, decoded: 2400), isNull);
    // scale2.5 dpr1 → 需要 2000：舊圖 1600 不夠 → 升 2400
    expect(bgUpgradeWidth(scale: 2.5, dpr: 1, decoded: 1600), 2400);
    // scale3 dpr1 → 需要 2400：正好夠
    expect(bgUpgradeWidth(scale: 3, dpr: 1, decoded: 2400), isNull);
    // scale4 dpr1 → 需要 3200 → 3200
    expect(bgUpgradeWidth(scale: 4, dpr: 1, decoded: 2400), 3200);
    // scale4 dpr2 → 需要 6400 → 頂到 4000
    expect(bgUpgradeWidth(scale: 4, dpr: 2, decoded: 2400), 4000);
    // 缺圖 decoded 0，scale1 → 補 2400
    expect(bgUpgradeWidth(scale: 1, dpr: 1, decoded: 0), 2400);
    // 已經 4000，再大也不動
    expect(bgUpgradeWidth(scale: 4, dpr: 2, decoded: 4000), isNull);
  });

  test('renderPdfPageAtWidth: 按源頁按寬渲染', () async {
    final doc = pw.Document();
    doc.addPage(
        pw.Page(pageFormat: PdfPageFormat.a4, build: (_) => pw.Text('p0')));
    doc.addPage(pw.Page(
        pageFormat: const PdfPageFormat(841.89, 595.28),
        build: (_) => pw.Text('p1')));
    final bytes = Uint8List.fromList(await doc.save());
    final r0 = await renderPdfPageAtWidth(bytes, 0, renderWidth: 1000);
    expect(r0, isNotNull);
    expect(r0!.w, 1000);
    expect(r0.h, closeTo(1414, 1));
    final r1 = await renderPdfPageAtWidth(bytes, 1, renderWidth: 1000);
    expect(r1, isNotNull);
    expect(r1!.w, 1000);
    expect(r1.h, closeTo(707, 1));
    // 越界 → null（調用方保留舊圖）
    expect(await renderPdfPageAtWidth(bytes, 5, renderWidth: 1000), isNull);
  });

  test('vector render: 生成PDF渲染出字+圖形（非全白）', () async {
    final doc = pw.Document();
    doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Center(
            child: pw.Column(children: [
          pw.Text('Hello vector', style: pw.TextStyle(fontSize: 40)),
          pw.Container(width: 200, height: 100, color: PdfColors.black),
        ]))));
    final bytes = Uint8List.fromList(await doc.save());
    final r = await renderPdfPageAtWidth(bytes, 0, renderWidth: 800);
    expect(r, isNotNull);
    expect(r!.w, 800);
    expect(r.h, closeTo(1131, 2));
    // 解码看像素：黑块+字，有落笔（package:pdf 用标准14号非嵌入字体，
    // 走系统字体兜底；Ahem 覆盖 ASCII，tofu 即方块也算落笔）
    final img = await decodePng(r.png);
    expect(img, isNotNull);
    final data =
        (await img!.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
    var dark = 0;
    for (var i = 0; i < data.length; i += 4 * 37) {
      if (data[i] < 128 || data[i + 1] < 128 || data[i + 2] < 128) dark++;
    }
    img.dispose();
    expect(dark, greaterThan(0));
  });
  testWidgets('two-finger pinch end fires onZoomEnd', (tester) async {
    var zoomEnd = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InkCanvas(
          strokes: const [],
          params: StrokeParams(
              maxSpeed: 1800,
              emaWeight: 0.6,
              thinning: 0.6,
              streamline: 0.5,
              size: 4.0),
          color: '#000000',
          size: 4.0,
          penType: PenType.brush,
          tool: ToolMode.pen,
          palmRejection: false,
          onStrokeCompleted: (_, _) {},
          onStrokeEraseTick: (_, _) {},
          onStrokeEraseEnd: () {},
          onPixelEraseCommitted: (_) {},
          panOffset: Offset.zero,
          scale: 1.0,
          onPanUpdate: (_) {},
          onZoomUpdate: (_, _) {},
          onZoomEnd: () => zoomEnd++,
          onPageFlick: (_) {},
          onTwoFingerDoubleTap: () {},
          onTwoFingerTripleTap: () {},
          onLassoCompleted: (_, _) {},
          onSelectionMove: (_) {},
          onSelectionRotate: (_, _) {},
          onSelectionEnd: () {},
          onDeselect: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final g1 = await tester.startGesture(const Offset(600, 400));
    final g2 = await tester.startGesture(const Offset(680, 400));
    await g1.moveTo(const Offset(560, 400));
    await g2.moveTo(const Offset(720, 400));
    await tester.pump();
    await g1.up();
    await tester.pump();
    await g2.up();
    await tester.pump();
    expect(zoomEnd, 1);
  });

  test('vector image path: 内嵌图行序正确（上红下蓝）', () async {
    // 400pt 页 central 200x200 图：上半红、下半蓝（翻转 bug 必现形）
    Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
    final raw = Uint8List.fromList([
      255, 0, 0, 255, 0, 0, // 上行：红
      0, 0, 255, 0, 0, 255, // 下行：蓝
    ]);
    final out = BytesBuilder();
    final offsets = <int>[];
    void obj(String body) {
      offsets.add(out.length);
      out.add(b(body));
    }

    out.add(b('%PDF-1.4\n'));
    obj('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
    obj('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
    obj('3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] '
        '/Resources << /XObject << /Im1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n');
    offsets.add(out.length);
    out.add(b('4 0 obj\n<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 '
        '/Length ${raw.length} >>\nstream\n'));
    out.add(raw);
    out.add(b('\nendstream\nendobj\n'));
    final content = b('q 200 0 0 200 100 100 cm /Im1 Do Q\n');
    offsets.add(out.length);
    out.add(b('5 0 obj\n<< /Length ${content.length} >>\nstream\n'));
    out.add(content);
    final xrefPos = out.length;
    out.add(b('\nendstream\nendobj\nxref\n0 6\n0000000000 65535 f \n${[
      for (final o in offsets) '${o.toString().padLeft(10, '0')} 00000 n '
    ].join('\n')}\ntrailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xrefPos\n%%EOF\n'));
    final bytes = out.toBytes();
    final doc = pdoc.PdfDocument.open(bytes);
    final stats = VectorRenderStats();
    final r = await renderPdfPageVector(doc, 0, widthPx: 400, stats: stats);
    expect(r, isNotNull);
    expect(stats.imagesOk, 1);
    // 图占屏 y 100~300（PDF y 100~300 翻转）：上半红、下半蓝
    final codec = await ui.instantiateImageCodec(r!.png);
    final frame = await codec.getNextFrame();
    final uiImg = frame.image;
    final data =
        (await uiImg.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
    var redTop = 0, blueBottom = 0;
    for (var y = 0; y < uiImg.height; y++) {
      for (var x = 0; x < uiImg.width; x++) {
        final o = (y * uiImg.width + x) * 4;
        final isRed = data[o] > 200 && data[o + 1] < 80 && data[o + 2] < 80;
        final isBlue = data[o + 2] > 200 && data[o] < 80 && data[o + 1] < 80;
        if (y >= 100 && y < 200 && isRed) redTop++;
        if (y >= 200 && y < 300 && isBlue) blueBottom++;
      }
    }
    uiImg.dispose();
    expect(redTop, greaterThan(10000));
    expect(blueBottom, greaterThan(10000));
  });

  testWidgets('palm rejection + pen: two touch fingers still zoom',
      (tester) async {
    var zoomed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InkCanvas(
          strokes: const [],
          params: StrokeParams(
              maxSpeed: 1800,
              emaWeight: 0.6,
              thinning: 0.6,
              streamline: 0.5,
              size: 4.0),
          color: '#000000',
          size: 4.0,
          penType: PenType.brush,
          tool: ToolMode.pen,
          palmRejection: true,
          onStrokeCompleted: (_, _) {},
          onStrokeEraseTick: (_, _) {},
          onStrokeEraseEnd: () {},
          onPixelEraseCommitted: (_) {},
          panOffset: Offset.zero,
          scale: 1.0,
          onPanUpdate: (_) {},
          onZoomUpdate: (_, _) {
            zoomed++;
          },
          onZoomEnd: () {},
          onPageFlick: (_) {},
          onTwoFingerDoubleTap: () {},
          onTwoFingerTripleTap: () {},
          onLassoCompleted: (_, _) {},
          onSelectionMove: (_) {},
          onSelectionRotate: (_, _) {},
          onSelectionEnd: () {},
          onDeselect: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final g1 = await tester.startGesture(const Offset(600, 400));
    final g2 = await tester.startGesture(const Offset(680, 400));
    await g1.moveTo(const Offset(560, 400));
    await g2.moveTo(const Offset(720, 400));
    await tester.pump();
    // 防誤觸只管落筆：雙指縮放必須照常觸發
    expect(zoomed, greaterThan(0));
    await g1.up();
    await tester.pump();
    await g2.up();
    await tester.pump();
  });

  testWidgets('stylus jitter does not kill dwell (shapes still snap)',
      (tester) async {
    var dwell = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InkCanvas(
          strokes: const [],
          params: StrokeParams(
              maxSpeed: 1800,
              emaWeight: 0.6,
              thinning: 0.6,
              streamline: 0.5,
              size: 4.0),
          color: '#000000',
          size: 4.0,
          penType: PenType.brush,
          tool: ToolMode.pen,
          palmRejection: true,
          onStrokeCompleted: (_, d) {
            dwell = d;
          },
          onStrokeEraseTick: (_, _) {},
          onStrokeEraseEnd: () {},
          onPixelEraseCommitted: (_) {},
          panOffset: Offset.zero,
          scale: 1.0,
          onPanUpdate: (_) {},
          onZoomUpdate: (_, _) {},
          onZoomEnd: () {},
          onPageFlick: (_) {},
          onTwoFingerDoubleTap: () {},
          onTwoFingerTripleTap: () {},
          onLassoCompleted: (_, _) {},
          onSelectionMove: (_) {},
          onSelectionRotate: (_, _) {},
          onSelectionEnd: () {},
          onDeselect: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final g = await tester.startGesture(const Offset(400, 400),
        kind: ui.PointerDeviceKind.stylus);
    // 事件 timeStamp 顯式遞增（tester 的手勢時鐘不隨 pump 推進，
    // dwell 只能靠顯式時間算；真機上 timeStamp 是真實時間）
    var t = const Duration(milliseconds: 100);
    Future<void> step(Offset p, int ms) async {
      t += Duration(milliseconds: ms);
      await g.moveTo(p, timeStamp: t);
    }

    await step(const Offset(460, 400), 100);
    await step(const Offset(460, 460), 100);
    await step(const Offset(400, 460), 100);
    await step(const Offset(400, 400), 100);
    // 原地噪聲 1.2s（每次位移 <6px）：修前會無限重計停頓＋刷新末點，
    // dwell≈100ms 形狀不修正；修後噪聲被吞，dwell 照算
    for (var i = 0; i < 12; i++) {
      await step(
          Offset(400.0 + (i % 2), 400.0 + ((i + 1) % 2)), 100);
      await tester.pump(const Duration(milliseconds: 100));
    }
    t += const Duration(milliseconds: 100);
    await g.up(timeStamp: t);
    await tester.pump();
    expect(dwell, greaterThanOrEqualTo(1000));
  });

  testWidgets('small slow writing keeps every point (no curve chording)',
      (tester) async {
    var npts = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InkCanvas(
          strokes: const [],
          params: StrokeParams(
              maxSpeed: 1800,
              emaWeight: 0.6,
              thinning: 0.6,
              streamline: 0.5,
              size: 4.0),
          color: '#000000',
          size: 4.0,
          penType: PenType.brush,
          tool: ToolMode.pen,
          palmRejection: true,
          onStrokeCompleted: (s, _) {
            npts = s.points.length;
          },
          onStrokeEraseTick: (_, _) {},
          onStrokeEraseEnd: () {},
          onPixelEraseCommitted: (_) {},
          panOffset: Offset.zero,
          scale: 1.0,
          onPanUpdate: (_) {},
          onZoomUpdate: (_, _) {},
          onZoomEnd: () {},
          onPageFlick: (_) {},
          onTwoFingerDoubleTap: () {},
          onTwoFingerTripleTap: () {},
          onLassoCompleted: (_, _) {},
          onSelectionMove: (_) {},
          onSelectionRotate: (_, _) {},
          onSelectionEnd: () {},
          onDeselect: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final g = await tester.startGesture(const Offset(400, 400),
        kind: ui.PointerDeviceKind.stylus);
    // 小字慢寫：每步 3px（小字彎道常態）。6px 一刀切會全吞再拉直線，
    // 「2」變「1」；修後只去重疊點（<1.5px），11 點全收
    var t = const Duration(milliseconds: 100);
    for (var i = 1; i <= 10; i++) {
      t += const Duration(milliseconds: 100);
      await g.moveTo(Offset(400.0 + i * 3, 400), timeStamp: t);
    }
    t += const Duration(milliseconds: 100);
    await g.up(timeStamp: t);
    await tester.pump();
    expect(npts, 11);
  });

  testWidgets('two-finger double tap fires immediately (no 500ms wait)',
      (tester) async {
    var undo = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InkCanvas(
          strokes: const [],
          params: StrokeParams(
              maxSpeed: 1800,
              emaWeight: 0.6,
              thinning: 0.6,
              streamline: 0.5,
              size: 4.0),
          color: '#000000',
          size: 4.0,
          penType: PenType.brush,
          tool: ToolMode.pen,
          palmRejection: false,
          onStrokeCompleted: (_, _) {},
          onStrokeEraseTick: (_, _) {},
          onStrokeEraseEnd: () {},
          onPixelEraseCommitted: (_) {},
          panOffset: Offset.zero,
          scale: 1.0,
          onPanUpdate: (_) {},
          onZoomUpdate: (_, _) {},
          onZoomEnd: () {},
          onPageFlick: (_) {},
          onTwoFingerDoubleTap: () {
            undo++;
          },
          onTwoFingerTripleTap: () {},
          onLassoCompleted: (_, _) {},
          onSelectionMove: (_) {},
          onSelectionRotate: (_, _) {},
          onSelectionEnd: () {},
          onDeselect: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    Future<void> tapOnce() async {
      final g1 = await tester.startGesture(const Offset(600, 400));
      final g2 = await tester.startGesture(const Offset(680, 400));
      await g1.up();
      await g2.up();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tapOnce();
    expect(undo, 0);
    await tapOnce();
    // 第二下抬起立刻 undo，不等 500ms（修前此處為 0）
    expect(undo, 1);
  });

  testWidgets('two-finger triple tap redoes twice (compensates early undo)',
      (tester) async {
    var undo = 0, redo = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InkCanvas(
          strokes: const [],
          params: StrokeParams(
              maxSpeed: 1800,
              emaWeight: 0.6,
              thinning: 0.6,
              streamline: 0.5,
              size: 4.0),
          color: '#000000',
          size: 4.0,
          penType: PenType.brush,
          tool: ToolMode.pen,
          palmRejection: false,
          onStrokeCompleted: (_, _) {},
          onStrokeEraseTick: (_, _) {},
          onStrokeEraseEnd: () {},
          onPixelEraseCommitted: (_) {},
          panOffset: Offset.zero,
          scale: 1.0,
          onPanUpdate: (_) {},
          onZoomUpdate: (_, _) {},
          onZoomEnd: () {},
          onPageFlick: (_) {},
          onTwoFingerDoubleTap: () {
            undo++;
          },
          onTwoFingerTripleTap: () {
            redo++;
          },
          onLassoCompleted: (_, _) {},
          onSelectionMove: (_) {},
          onSelectionRotate: (_, _) {},
          onSelectionEnd: () {},
          onDeselect: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    Future<void> tapOnce() async {
      final g1 = await tester.startGesture(const Offset(600, 400));
      final g2 = await tester.startGesture(const Offset(680, 400));
      await g1.up();
      await g2.up();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tapOnce();
    await tapOnce();
    await tapOnce();
    // 兩下時已提前 undo 一次；三下 redo 兩次（先撤銷提前的 undo，
    // 再 redo 本義），淨效果 1 redo
    expect(undo, 1);
    expect(redo, 2);
  });

  test('pageBoxMetas: 不渲染给全部页建条目', () async {
    final doc = pw.Document();
    doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4, build: (_) => pw.Text('p0')));
    doc.addPage(pw.Page(
        pageFormat: const PdfPageFormat(841.89, 595.28),
        build: (_) => pw.Text('p1')));
    final bytes = Uint8List.fromList(await doc.save());
    final metas = pageBoxMetas(bytes);
    expect(metas.length, 2);
    expect(metas[0].src, 0);
    expect(metas[0].w, 2400);
    expect(metas[0].h, closeTo(3394, 2));
    expect(metas[1].src, 1);
    expect(metas[1].w, 2400);
    expect(metas[1].h, closeTo(1697, 2));
    // 垃圾字节抛错（调用方走打不开流程）
    expect(() => pageBoxMetas(Uint8List.fromList([1, 2, 3])), throwsA(anything));
  });
}
