import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/models/note.dart';
import 'package:ink_notes/storage/memory_note_store.dart';

/// 內存實現與文件實現同語義（Web 預覽用，純 Dart，可跑在 VM/無頭環境）。
void main() {
  late MemoryNoteStore store;

  setUp(() {
    store = MemoryNoteStore();
  });

  Note note(String id, int strokes) => Note(
        id: id,
        title: 't-$id',
        createdAt: DateTime.utc(2026, 10, 5),
        updatedAt: DateTime.utc(2026, 10, 5),
        strokes: List.generate(
          strokes,
          (i) => Stroke(color: '#000000', size: 4.0, points: [
            NotePoint(x: i.toDouble(), y: 0, p: 1.0, t: 0),
          ]),
        ),
      );

  test('save + load 往返', () async {
    await store.save(note('a1b2', 2));
    final loaded = await store.load('a1b2');
    expect(loaded.strokes.length, 2);
    expect((await store.listAll()).length, 1);
  });

  test('二次保存產生歷史並可回滾', () async {
    await store.save(note('a1b2', 1));
    await store.save(note('a1b2', 2));
    final hist = await store.listHistory('a1b2');
    expect(hist.length, 1);
    expect(hist.first.endsWith('.json'), isTrue);
    final rolled = await store.rollback('a1b2', hist.first);
    expect(rolled.strokes.length, 1);
    expect((await store.load('a1b2')).strokes.length, 1);
  });

  test('縮圖存取 + 刪除', () async {
    await store.save(note('a1b2', 1));
    expect(await store.loadThumbnail('a1b2'), isNull);
    await store.saveThumbnail('a1b2', [1, 2, 3]);
    expect(await store.loadThumbnail('a1b2'), [1, 2, 3]);
    await store.delete('a1b2');
    expect((await store.listAll()).isEmpty, isTrue);
  });
}
