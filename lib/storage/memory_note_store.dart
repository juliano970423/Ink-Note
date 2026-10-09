import 'dart:convert';
import 'dart:typed_data';

import '../models/note.dart';
import 'note_store.dart';

/// 純 Dart 內存實現（Web 預覽用）：語義與文件實現對齊，
/// 歷史快照存 JSON 原文（內存本就短命，無需 gzip；reload 後丟失，僅供 UI/手感測試）。
class MemoryNoteStore implements NoteStore {
  final Map<String, String> _notes = {};
  final Map<String, List<_Snapshot>> _history = {};
  final Map<String, Uint8List> _thumbs = {};
  final Map<String, Map<String, Uint8List>> _backgrounds = {};
  final Map<String, Uint8List> _originalPdfs = {};

  @override
  Future<void> save(Note note) async {
    note.updatedAt = DateTime.now().toUtc();
    final old = _notes[note.id];
    if (old != null) {
      final snaps = _history.putIfAbsent(note.id, () => []);
      final stamp = _stamp(DateTime.now().toUtc());
      snaps.add(_Snapshot(
        'v${snaps.length + 1}_$stamp.json',
        Uint8List.fromList(utf8.encode(old)),
      ));
    }
    _notes[note.id] = note.encode();
    // TODO(保留策略): history/ 目前不設上限，未來加按數量/時間清理。
    // TODO(同步合併): 未來接 MEGA 同步時雙端同改同一篇，利用 history/ 快照按筆畫時間戳合併。
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}T${two(t.hour)}${two(t.minute)}';
  }

  @override
  Future<List<Note>> listAll() async {
    final out = _notes.values.map(Note.decode).toList();
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  @override
  Future<Note> load(String id) async {
    final raw = _notes[id];
    if (raw == null) throw StateError('note not found: $id');
    return Note.decode(raw);
  }

  @override
  Future<List<String>> listHistory(String id) async {
    final snaps = _history[id] ?? const <_Snapshot>[];
    final names = snaps.map((s) => s.name).toList()..sort();
    return names;
  }

  @override
  Future<Note> rollback(String id, String historyFile) async {
    final snaps = _history[id] ?? const <_Snapshot>[];
    final hit = snaps.where((s) => s.name == historyFile);
    if (hit.isEmpty) throw StateError('history not found: $historyFile');
    final jsonStr = utf8.decode(hit.first.bytes);
    final note = Note.decode(jsonStr);
    note.updatedAt = DateTime.now().toUtc();
    await save(note);
    return note;
  }

  @override
  Future<Uint8List?> loadThumbnail(String id) async => _thumbs[id];

  @override
  Future<void> saveThumbnail(String id, List<int> pngBytes) async {
    _thumbs[id] = Uint8List.fromList(pngBytes);
  }

  @override
  Future<Uint8List?> loadBackground(String id, String key) async =>
      _backgrounds[id]?[key];

  @override
  Future<void> saveBackground(
      String id, String key, List<int> pngBytes) async {
    (_backgrounds[id] ??= {})[key] = Uint8List.fromList(pngBytes);
  }

  @override
  Future<Uint8List?> loadOriginalPdf(String id) async => _originalPdfs[id];

  @override
  Future<void> saveOriginalPdf(String id, List<int> pdfBytes) async {
    _originalPdfs[id] = Uint8List.fromList(pdfBytes);
  }

  @override
  Future<void> delete(String id) async {
    _notes.remove(id);
    _thumbs.remove(id);
    _backgrounds.remove(id);
    _originalPdfs.remove(id);
  }

  @override
  Future<List<String>> listFolders() async {
    final folders = <String>{};
    for (final raw in _notes.values) {
      final f = Note.decode(raw).folder;
      if (f.isNotEmpty) folders.add(f);
    }
    final out = folders.toList()..sort();
    return out;
  }

  @override
  Future<void> deleteFolder(String folder) async {
    for (final raw in _notes.values) {
      if (Note.decode(raw).folder == folder) {
        throw StateError('folder not empty: $folder');
      }
    }
  }
}

class _Snapshot {
  final String name;
  final Uint8List bytes;
  const _Snapshot(this.name, this.bytes);
}
