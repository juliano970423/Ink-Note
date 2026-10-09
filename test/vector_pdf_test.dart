import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/export/vector_pdf.dart';
import 'package:ink_notes/models/note.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart' as pdoc;

Future<List<int>> _samplePdf() async {
  final doc = pw.Document();
  doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (_) => pw.Center(
          child: pw.Text('hello vector',
              style: pw.TextStyle(fontSize: 40)))));
  return doc.save();
}

/// 兩頁不同方向（A4 直 + A4 橫），靠尺寸驗重排順序。
Future<List<int>> _twoPagePdf() async {
  final doc = pw.Document();
  doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4, build: (_) => pw.Text('first')));
  doc.addPage(
      pw.Page(pageFormat: const PdfPageFormat(841.89, 595.28),
      build: (_) => pw.Text('second')));
  return doc.save();
}

Stroke _line() => const Stroke(
      color: '#000000',
      size: 4.0,
      points: [
        NotePoint(x: 100, y: 100, p: 1, t: 0),
        NotePoint(x: 200, y: 150, p: 1, t: 10),
      ],
    );

void main() {
  test('座標映射：原點/對角/旋轉', () {
    List<NotePoint> pts(List<List<double>> xys) => [
          for (var i = 0; i < xys.length; i++)
            NotePoint(x: xys[i][0], y: xys[i][1], p: 1, t: i),
        ];
    // 800×1000 顯示對 100×200 pt 頁：左上→(0,200)，右下→(100,0)
    final m = mapStrokeToPdf(
      pts([
        [24, 24],
        [824, 1024],
      ]),
      dispH: 1000,
      rotW: 100,
      rotH: 200,
      unrotW: 100,
      unrotH: 200,
      cropLeft: 0,
      cropBottom: 0,
      rotation: 0,
    );
    expect(m[0].$1, closeTo(0, 1e-6));
    expect(m[0].$2, closeTo(200, 1e-6));
    expect(m[1].$1, closeTo(100, 1e-6));
    expect(m[1].$2, closeTo(0, 1e-6));
    // 旋轉 90°：顯示左上 = 未旋轉左下（順時針 BL→TL）
    final r = mapStrokeToPdf(
      pts([
        [24, 24]
      ]),
      dispH: 1000,
      rotW: 200,
      rotH: 100,
      unrotW: 100,
      unrotH: 200,
      cropLeft: 0,
      cropBottom: 0,
      rotation: 90,
    );
    expect(r[0].$1, closeTo(0, 1e-6));
    expect(r[0].$2, closeTo(0, 1e-6));
    // 旋轉 270°：顯示左上 = 未旋轉右上（逆時針 TR→TL）
    final r270 = mapStrokeToPdf(
      pts([
        [24, 24]
      ]),
      dispH: 1000,
      rotW: 200,
      rotH: 100,
      unrotW: 100,
      unrotH: 200,
      cropLeft: 0,
      cropBottom: 0,
      rotation: 270,
    );
    expect(r270[0].$1, closeTo(100, 1e-6));
    expect(r270[0].$2, closeTo(200, 1e-6));
  });

  test('向量匯出：增量前綴+可重解析+隱藏層跳過', () async {
    final orig = await _samplePdf();
    final strokes = [
      _line(),
      const Stroke(
        color: '#ff0000',
        size: 4.0,
        points: [
          NotePoint(x: 300, y: 300, p: 1, t: 0),
          NotePoint(x: 400, y: 300, p: 1, t: 8),
          NotePoint(x: 400, y: 400, p: 1, t: 16),
          NotePoint(x: 300, y: 400, p: 1, t: 24),
          NotePoint(x: 300, y: 300, p: 1, t: 32),
        ],
        geometric: true,
      ),
    ];
    final out = buildVectorPdf(
      original: Uint8List.fromList(orig),
      strokes: strokes,
      backgrounds: const [PageBg(w: 800, h: 1131)],
    );
    // 增量更新：原文是輸出前綴
    expect(out.length, greaterThan(orig.length));
    for (var i = 0; i < orig.length; i++) {
      expect(out[i], orig[i]);
    }
    // 可重解析，頁數不變
    final reopened = pdoc.PdfDocument.open(out);
    expect(reopened.pageCount, 1);
    // 隱藏層寫入會更大：只寫 layer 0（用 copyWith 換層驗證過濾在調用方，
    // 這裡直接驗不同筆數輸出不同）
    final outEmpty = buildVectorPdf(
      original: Uint8List.fromList(orig),
      strokes: const [],
      backgrounds: const [PageBg(w: 800, h: 1131)],
    );
    expect(outEmpty.length, greaterThan(orig.length));
    expect(out.length, greaterThan(outEmpty.length));
  });

  test('向量匯出：垃圾字節拋錯（調用方回退光柵）', () {
    expect(
        () => buildVectorPdf(
              original: Uint8List.fromList([1, 2, 3, 4]),
              strokes: [_line()],
              backgrounds: const [PageBg(w: 800, h: 1131)],
            ),
        throwsA(anything));
  });

  test('向量匯出：頁面重排按顯示順序寫', () async {
    final orig = await _twoPagePdf();
    // 顯示頁 0 ← 原第 2 頁（橫），顯示頁 1 ← 原第 1 頁（直）
    final out = buildVectorPdf(
      original: Uint8List.fromList(orig),
      strokes: [_line()],
      backgrounds: const [
        PageBg(w: 1131, h: 800, key: 'a', src: 1),
        PageBg(w: 800, h: 1131, key: 'b', src: 0),
      ],
    );
    final reopened = pdoc.PdfDocument.open(out);
    expect(reopened.pageCount, 2);
    // 第 0 頁變橫向（原第 2 頁搬上來）
    expect(reopened.pages[0].cropBox.width,
        greaterThan(reopened.pages[0].cropBox.height));
    expect(reopened.pages[1].cropBox.height,
        greaterThan(reopened.pages[1].cropBox.width));
    // 顯示第 0 頁的筆跟著落在文件第 0 頁
    expect(
        reopened.pages[0].annotations
            .where((a) => a.subtype == 'Ink')
            .length,
        1);
    expect(
        reopened.pages[1].annotations
            .where((a) => a.subtype == 'Ink')
            .length,
        0);
  });

  test('向量匯出：刪頁+空白頁', () async {
    final orig = await _twoPagePdf();
    // 顯示只有：原第 2 頁 + 一張空白頁（原第 1 頁被刪）
    final out = buildVectorPdf(
      original: Uint8List.fromList(orig),
      strokes: [_line().copyWith(page: 1)],
      backgrounds: const [
        PageBg(w: 1131, h: 800, key: 'a', src: 1),
        PageBg(w: 1131, h: 800, key: 'c'),
      ],
    );
    final reopened = pdoc.PdfDocument.open(out);
    expect(reopened.pageCount, 2);
    expect(reopened.pages[0].cropBox.width,
        greaterThan(reopened.pages[0].cropBox.height));
    // 空白頁尺寸參照鄰頁（橫向）
    expect(reopened.pages[1].cropBox.width,
        greaterThan(reopened.pages[1].cropBox.height));
    // 筆在顯示第 2 頁 → 文件第 2 頁
    expect(
        reopened.pages[1].annotations
            .where((a) => a.subtype == 'Ink')
            .length,
        1);
  });

  test('向量匯出：源頁全刪光拋錯（調用方回退光柵）', () async {
    final orig = await _twoPagePdf();
    expect(
        () => buildVectorPdf(
              original: Uint8List.fromList(orig),
              strokes: const [],
              backgrounds: const [
                PageBg(w: 800, h: 1131, key: 'c'),
                PageBg(w: 800, h: 1131, key: 'd'),
              ],
            ),
        throwsA(anything));
  });
}
