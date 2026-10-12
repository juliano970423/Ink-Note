import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/export/note_pdf.dart';
import 'package:ink_notes/models/note.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf_document/pdf_document.dart' as pdoc;

import 'test_png.dart';

Note _note({String? pageId, int strokes = 2}) => Note(
  id: 'a1b2',
  title: 'pdf測試',
  createdAt: DateTime.utc(2026, 10, 5),
  updatedAt: DateTime.utc(2026, 10, 5),
  pageId: pageId,
  strokes: List.generate(
    strokes,
    (i) => Stroke(
      color: '#000000',
      size: 4.0,
      points: [
        NotePoint(x: 100.0 + i * 50, y: 100, p: 1.0, t: 0),
        NotePoint(x: 120.0 + i * 50, y: 150, p: 0.8, t: 10),
      ],
    ),
  ),
);

void main() {
  test('A4 匯出為有效 PDF', () async {
    final bytes = await buildNotePdf(_note(pageId: 'A4'));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // 全向量：兩筆體量很小（光柵時代要幾十 KB），只驗非空殼
    expect(bytes.length, greaterThan(500));
  });

  test('無限畫布 + 空筆記皆可匯出', () async {
    final bytes = await buildNotePdf(_note());
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final empty = await buildNotePdf(_note(strokes: 0));
    expect(String.fromCharCodes(empty.take(5)), '%PDF-');
  });

  test('多頁 A4 逐頁匯出', () async {
    final n = _note(pageId: 'A4');
    n.strokes.add(
      Stroke(
        color: '#ff0000',
        size: 4.0,
        points: const [NotePoint(x: 100, y: 100, p: 1.0, t: 0)],
        page: 1,
      ),
    );
    final bytes = await buildNotePdf(n);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final text = String.fromCharCodes(bytes);
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
    expect(pages, 2);
  });

  test('顯示→頁面映射：左上原點、y 上翻', () {
    // 210mm 寬頁（595.28pt）對 800px 顯示寬
    final map = ExportPageMap(
        srcX: 24, srcY: 24, srcW: 800, srcH: 1000,
        format: const PdfPageFormat(595.28, 700));
    final sc = 595.28 / 800;
    expect(map.px(24), closeTo(0, 1e-6));
    expect(map.px(824), closeTo(595.28, 1e-6));
    expect(map.py(24), closeTo(1000 * sc, 1e-6));
    expect(map.py(1024), closeTo(0, 1e-6));
  });

  test('無限畫布匯出含圖片且保持向量體量', () async {
    final n = _note();
    const img = NoteImage(id: 'im1', page: 0, x: 100, y: 100, w: 200, h: 100);
    final png = tinyPng();
    final withImg = await buildNotePdf(n,
        images: const [img], imageBytes: {'im1': png});
    expect(String.fromCharCodes(withImg.take(5)), '%PDF-');
    final reopened = pdoc.PdfDocument.open(withImg);
    expect(reopened.pageCount, 1);
    // 向量體量：整頁 150dpi 光柵至少幾十 KB，向量幾 KB 搞定
    expect(withImg.length, lessThan(30000));
    // 圖有進去：比沒圖大
    final withoutImg = await buildNotePdf(n);
    expect(withImg.length, greaterThan(withoutImg.length));
  });
}
