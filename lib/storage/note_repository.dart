import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import 'note_store.dart';

/// 本地存儲佈局：
/// ```text
/// <appDocs>/MyInkNotes/
///    ├── notes/
///    │   ├── 2026-10-05_會議記錄_a3f8c2.json (+ 同名 .png 縮圖)
///    │   └── 工作/2026-10-05_週會_b71c.json   (資料夾 = 子目錄)
///    └── history/
///        └── 2026-10-05_會議記錄_a3f8c2/   (無副檔名 = 該筆記的歷史目錄)
///            ├── v1_20261005T1730.json.gz
///            └── v2_20261005T1815.json.gz
/// ```
class NoteRepository implements NoteStore {
  final Directory root;

  NoteRepository(this.root);

  Directory get notesDir => Directory(p.join(root.path, 'notes'));
  Directory get historyDir => Directory(p.join(root.path, 'history'));

  /// 正式環境入口：用 path_provider 定位文檔目錄。
  static Future<NoteRepository> createDefault() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'MyInkNotes'));
    final repo = NoteRepository(root);
    await repo.ensureDirs();
    return repo;
  }

  /// 測試/注入用：指定根目錄。
  static Future<NoteRepository> createAt(Directory root) async {
    final repo = NoteRepository(root);
    await repo.ensureDirs();
    return repo;
  }

  Future<void> ensureDirs() async {
    await notesDir.create(recursive: true);
    await historyDir.create(recursive: true);
  }

  /// 該筆記歷史目錄名 = 筆記文件名去掉 .json
  String historyKeyForFileName(String noteFileName) =>
      noteFileName.replaceAll(RegExp(r'\.json$'), '');

  Directory historyDirFor(String historyKey) =>
      Directory(p.join(historyDir.path, historyKey));

  /// 筆記所屬目錄（folder 為 '' 時即 notes/ 根）。
  Directory dirForFolder(String folder) {
    final f = Note.sanitizeFolder(folder);
    return f.isEmpty ? notesDir : Directory(p.join(notesDir.path, f));
  }

  /// 在 notes/ 下遞歸按 id 查找現有文件（改名/搬資料夾都會變路徑，故按 id 匹配後綴 `_$id.json`）。
  Future<File?> findNoteFile(String id) async {
    if (!await notesDir.exists()) return null;
    await for (final e in notesDir.list(recursive: true)) {
      if (e is File &&
          !e.path.endsWith('.tmp') &&
          e.path.endsWith('_$id.json')) {
        return e;
      }
    }
    return null;
  }

  /// 保存筆記：
  /// ① 若 notes/ 已有同 id 文件，先把舊內容 gzip 複製進 history/{key}/ 為 v{n}_{時間戳}.json.gz
  /// ② 原子寫入新內容（先寫 .tmp 再 rename）。
  /// 若改名/搬資料夾導致路徑變化，刪除舊文件（含舊縮圖）。
  @override
  Future<void> save(Note note) async {
    await ensureDirs();
    note.folder = Note.sanitizeFolder(note.folder);
    note.updatedAt = DateTime.now().toUtc();
    final dir = dirForFolder(note.folder);
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, note.fileName()));
    final existing = await findNoteFile(note.id);

    if (existing != null) {
      final oldBytes = await existing.readAsBytes();
      final historyKey = historyKeyForFileName(p.basename(existing.path));
      final hdir = historyDirFor(historyKey);
      await hdir.create(recursive: true);
      final next = await _nextVersion(hdir);
      final stamp = _stamp(DateTime.now().toUtc());
      final histFile =
          File(p.join(hdir.path, 'v${next}_$stamp.json.gz'));
      await histFile.writeAsBytes(gzip.encode(oldBytes));
      // 若改名/搬家：歷史目錄保持舊 key（可追溯），刪除舊文件；新文件用新路徑。
      if (existing.path != target.path) {
        await existing.delete();
        final oldThumb = File(existing.path.replaceAll(
            RegExp(r'\.json$'), '.png'));
        if (await oldThumb.exists()) {
          try {
            await oldThumb.delete();
          } catch (_) {}
        }
      }
    }

    // 原子寫入：先寫 .tmp 再 rename
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(note.encode(), flush: true);
    await tmp.rename(target.path);
    // TODO(保留策略): history/ 目前不設上限（筆記體量小），未來加按數量/時間清理。
    // TODO(同步合併): 未來接 MEGA 同步時雙端同改同一篇，利用 history/ 快照按筆畫時間戳合併（見 SyncBackend）。
  }

  Future<int> _nextVersion(Directory hdir) async {
    var max = 0;
    await for (final e in hdir.list()) {
      if (e is! File) continue;
      final m = RegExp(r'^v(\d+)_').firstMatch(p.basename(e.path));
      if (m != null) {
        final v = int.tryParse(m.group(1)!) ?? 0;
        if (v > max) max = v;
      }
    }
    return max + 1;
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}T${two(t.hour)}${two(t.minute)}';
  }

  @override
  Future<List<Note>> listAll() async {
    await ensureDirs();
    final out = <Note>[];
    await for (final e in notesDir.list(recursive: true)) {
      if (e is File && e.path.endsWith('.json') && !e.path.endsWith('.tmp')) {
        try {
          out.add(Note.decode(await e.readAsString()));
        } catch (_) {
          // 壞文件跳過，不讓整個列表掛掉
        }
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  @override
  Future<List<String>> listFolders() async {
    await ensureDirs();
    final out = <String>[];
    await for (final e in notesDir.list()) {
      if (e is Directory) out.add(p.basename(e.path));
    }
    out.sort();
    return out;
  }

  @override
  Future<void> deleteFolder(String folder) async {
    final dir = dirForFolder(folder);
    if (!await dir.exists()) return;
    // 非空拒刪：先把筆記搬走再調用。
    final entries = await dir.list().toList();
    if (entries.isNotEmpty) {
      throw StateError('folder not empty: $folder');
    }
    await dir.delete();
  }

  @override
  Future<Note> load(String id) async {
    final f = await findNoteFile(id);
    if (f == null) throw StateError('note not found: $id');
    return Note.decode(await f.readAsString());
  }

  /// 列出該筆記所有歷史快照文件名（已排序）。
  @override
  Future<List<String>> listHistory(String id) async {
    // 歷史目錄 key 可能來自舊文件名，需掃描 history/ 下後綴匹配 `_$id` 的目錄。
    if (!await historyDir.exists()) return [];
    final keys = <String>[];
    await for (final e in historyDir.list()) {
      if (e is Directory && p.basename(e.path).endsWith('_$id')) {
        keys.add(e.path);
      }
    }
    final files = <String>[];
    for (final k in keys) {
      await for (final f in Directory(k).list()) {
        if (f is File && f.path.endsWith('.json.gz')) {
          files.add(p.basename(f.path));
        }
      }
    }
    files.sort();
    return files;
  }

  /// 歷史快照的完整路徑（給 UI 展示/回滾用）。
  Future<List<File>> listHistoryFiles(String id) async {
    if (!await historyDir.exists()) return [];
    final out = <File>[];
    await for (final e in historyDir.list()) {
      if (e is Directory && p.basename(e.path).endsWith('_$id')) {
        await for (final f in e.list()) {
          if (f is File && f.path.endsWith('.json.gz')) out.add(f);
        }
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// 回滾：把歷史版本（gzip）解壓複製回 notes/（同樣走原子寫入 + 先備份當前版）。
  @override
  Future<Note> rollback(String id, String historyFileName) async {
    final histFiles = await listHistoryFiles(id);
    final hist = histFiles.where((f) => p.basename(f.path) == historyFileName);
    if (hist.isEmpty) throw StateError('history not found: $historyFileName');
    final bytes = await hist.first.readAsBytes();
    final jsonStr = utf8.decode(gzip.decode(bytes));
    final note = Note.decode(jsonStr);
    // rollback 視為一次新的保存：先備份當前版，再寫入歷史內容（更新 updatedAt）。
    note.updatedAt = DateTime.now().toUtc();
    await save(note);
    return note;
  }

  /// 縮圖：與 note json 同目錄同 basename 的 .png。
  Future<File> thumbnailFileForId(String id) async {
    final f = await findNoteFile(id);
    if (f == null) throw StateError('note not found: $id');
    return File(f.path.replaceAll(RegExp(r'\.json$'), '.png'));
  }

  @override
  Future<Uint8List?> loadThumbnail(String id) async {
    try {
      final thumb = await thumbnailFileForId(id);
      if (await thumb.exists()) return await thumb.readAsBytes();
    } catch (_) {}
    return null;
  }

  @override
  Future<void> saveThumbnail(String id, List<int> pngBytes) async {
    final thumb = await thumbnailFileForId(id);
    final tmp = File('${thumb.path}.tmp');
    await tmp.writeAsBytes(pngBytes, flush: true);
    await tmp.rename(thumb.path);
  }

  /// PDF 底圖：與 note json 同目錄，`{basename}_bg{key}.png`
  ///（key 只含字母數字，舊版按頁編號的 `_bg{i}.png` 首次讀到自動改名）。
  Future<File> backgroundFileForId(String id, String key) async {
    final f = await findNoteFile(id);
    if (f == null) throw StateError('note not found: $id');
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(f.path.replaceAll(RegExp(r'\.json$'), '_bg$safe.png'));
  }

  @override
  Future<Uint8List?> loadBackground(String id, String key) async {
    try {
      final bg = await backgroundFileForId(id, key);
      if (await bg.exists()) return await bg.readAsBytes();
      // 舊版文件：key `p{i}` 對應舊檔名 `_bg{i}.png`，搬過來
      final m = RegExp(r'^p(\d+)$').firstMatch(key);
      if (m != null) {
        final f = await findNoteFile(id);
        if (f != null) {
          final legacy =
              File(f.path.replaceAll(RegExp(r'\.json$'), '_bg${m[1]}.png'));
          if (await legacy.exists()) {
            await legacy.rename(bg.path);
            return await bg.readAsBytes();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> saveBackground(
      String id, String key, List<int> pngBytes) async {
    final bg = await backgroundFileForId(id, key);
    final tmp = File('${bg.path}.tmp');
    await tmp.writeAsBytes(pngBytes, flush: true);
    await tmp.rename(bg.path);
  }

  /// 匯入的原 PDF：`{basename}_orig.pdf`（向量源頭）。
  Future<File> originalPdfFileForId(String id) async {
    final f = await findNoteFile(id);
    if (f == null) throw StateError('note not found: $id');
    return File(f.path.replaceAll(RegExp(r'\.json$'), '_orig.pdf'));
  }

  @override
  Future<Uint8List?> loadOriginalPdf(String id) async {
    try {
      final f = await originalPdfFileForId(id);
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  @override
  Future<void> saveOriginalPdf(String id, List<int> pdfBytes) async {
    final f = await originalPdfFileForId(id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(pdfBytes, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String id) async {
    final f = await findNoteFile(id);
    if (f != null) {
      await f.delete();
      final thumb = File(f.path.replaceAll(RegExp(r'\.json$'), '.png'));
      if (await thumb.exists()) await thumb.delete();
      final orig = File(f.path.replaceAll(RegExp(r'\.json$'), '_orig.pdf'));
      if (await orig.exists()) await orig.delete();
      // 底圖按 key 存檔（`_bg*.png` 全刪；刪頁留下的孤兒文件在這裡一起清）
      final dir = f.parent;
      final base = f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), '');
      await for (final e in dir.list()) {
        final name = e.uri.pathSegments.last;
        if (name.startsWith('${base}_bg') && name.endsWith('.png')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
  }
}
