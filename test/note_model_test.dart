import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';

void main() {
  test('note json 往返一致（p 直接存、不重算）', () {
    final note = Note(
      id: 'a3f8c2',
      title: '會議記錄',
      createdAt: DateTime.utc(2026, 10, 5, 17, 30),
      updatedAt: DateTime.utc(2026, 10, 5, 18, 15),
      strokes: [
        const Stroke(color: '#000000', size: 4.0, points: [
          NotePoint(x: 120.5, y: 88.2, p: 0.42, t: 0),
          NotePoint(x: 122.1, y: 90.0, p: 0.45, t: 8),
        ]),
      ],
    );
    final rt = Note.decode(note.encode());
    expect(rt.id, 'a3f8c2');
    expect(rt.title, '會議記錄');
    expect(rt.strokes.length, 1);
    expect(rt.strokes.first.points[0].p, 0.42);
    expect(rt.strokes.first.points[1].t, 8);
  });

  test('id 為 4~6 位 hex', () {
    for (var i = 0; i < 50; i++) {
      final id = Note.newId();
      expect(RegExp(r'^[0-9a-f]{4,6}$').hasMatch(id), isTrue,
          reason: 'bad id: $id');
    }
  });

  test('folder/page 往返 + 舊文件預設值', () {
    final note = Note(
      id: 'a3f8c2',
      title: 't',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
      folder: '工作',
      pageId: 'A4',
    );
    final rt = Note.decode(note.encode());
    expect(rt.folder, '工作');
    expect(rt.pageId, 'A4');
    // 舊文件：無 folder/page 欄位 → 根目錄/無限畫布
    final legacy = Note.decode(
        '{"version":1,"id":"ab12","title":"old","createdAt":"2026-10-05T17:30:00Z","updatedAt":"2026-10-05T17:30:00Z","strokes":[]}');
    expect(legacy.folder, '');
    expect(legacy.pageId, isNull);
    expect(Note.sanitizeFolder('  '), '');
    expect(Note.sanitizeFolder('a/b'), 'a_b');
    expect(PageSize.byId('A4')!.wMm, 210);
    expect(PageSize.byId(null), isNull);
  });

  test('文件名格式與非法字符過濾', () {
    final note = Note(
      id: 'a3f8c2',
      title: '會議記錄',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
    );
    expect(note.fileName(date: DateTime(2026, 10, 5)),
        '2026-10-05_會議記錄_a3f8c2.json');
    final bad = Note(
      id: 'abcd',
      title: 'a/b:c*d?e"f<g>h|i',
      createdAt: DateTime.utc(2026, 10, 5),
      updatedAt: DateTime.utc(2026, 10, 5),
    );
    final fn = bad.fileName(date: DateTime(2026, 10, 5));
    expect(fn.contains('/'), isFalse);
    expect(fn.contains(':'), isFalse);
    expect(fn.endsWith('_abcd.json'), isTrue);
  });
}
