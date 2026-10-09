import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/export/note_pdf.dart';
import 'package:ink_notes/models/note.dart';

Note _note({String? pageId, int strokes = 2}) => Note(
      id: 'a1b2',
      title: 'pdf測試',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      pageId: pageId,
      strokes: List.generate(
        strokes,
        (i) => Stroke(color: '#000000', size: 4.0, points: [
          NotePoint(x: 100.0 + i * 50, y: 100, p: 1.0, t: 0),
          NotePoint(x: 120.0 + i * 50, y: 150, p: 0.8, t: 10),
        ]),
      ),
    );

void main() {
  test('A4 匯出為有效 PDF', () async {
    final bytes = await buildNotePdf(_note(pageId: 'A4'));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  test('無限畫布 + 空筆記皆可匯出', () async {
    final bytes = await buildNotePdf(_note());
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final empty = await buildNotePdf(_note(strokes: 0));
    expect(String.fromCharCodes(empty.take(5)), '%PDF-');
  });

  test('多頁 A4 逐頁匯出', () async {
    final n = _note(pageId: 'A4');
    n.strokes.add(Stroke(color: '#ff0000', size: 4.0, points: const [
      NotePoint(x: 100, y: 100, p: 1.0, t: 0),
    ], page: 1));
    final bytes = await buildNotePdf(n);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final text = String.fromCharCodes(bytes);
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
    expect(pages, 2);
  });
}
