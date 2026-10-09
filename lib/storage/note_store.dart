import 'dart:typed_data';

import '../models/note.dart';

/// 筆記存儲接口（純 Dart，不依賴 dart:io，可在 Web 使用）。
/// 桌面/移動端由 [NoteRepository]（文件 + gzip 歷史）實現；
/// Web 預覽由內存實現承接（reload 不持久，僅供 UI/筆跡手感測試）。
abstract class NoteStore {
  /// 保存筆記；若已存在同 id，先快照舊版進歷史，再原子寫入新版。
  Future<void> save(Note note);

  /// 列出全部筆記（按 updatedAt 倒序）。
  Future<List<Note>> listAll();

  Future<Note> load(String id);

  /// 該筆記的歷史快照名列表（已排序，如 v1_20261005T1730.json.gz）。
  Future<List<String>> listHistory(String id);

  /// 把歷史快照恢復為當前版（恢復本身也會先快照當前版）。
  Future<Note> rollback(String id, String historyFile);

  /// 縮圖 PNG 字節；無縮圖返回 null。
  Future<Uint8List?> loadThumbnail(String id);

  Future<void> saveThumbnail(String id, List<int> pngBytes);

  /// PDF 底圖 PNG（每頁一張，按底圖 key 存）；無底圖返回 null。
  Future<Uint8List?> loadBackground(String id, String key);

  Future<void> saveBackground(String id, String key, List<int> pngBytes);

  /// 匯入的原 PDF 字節（向量源頭，為將來向量匯出保留；普通筆記為 null）。
  Future<Uint8List?> loadOriginalPdf(String id);

  Future<void> saveOriginalPdf(String id, List<int> pdfBytes);

  Future<void> delete(String id);

  /// 列出所有資料夾名（已排序，不含根目錄）。
  Future<List<String>> listFolders();

  /// 刪除空資料夾（非空則拋錯；先把筆記搬走再調用）。
  Future<void> deleteFolder(String folder);
}
