/// 同步後端抽象（本期只定義接口，不實現）。
/// 本地 `notes/` 是唯一真相來源，離線優先。
abstract class SyncBackend {
  Future<List<RemoteFileInfo>> list(String remotePath);
  Future<String> download(String remotePath);
  Future<void> upload(String remotePath, String localPath);
  Future<void> delete(String remotePath);
}

class RemoteFileInfo {
  final String path;
  final DateTime updatedAt;
  final String id;

  const RemoteFileInfo({
    required this.path,
    required this.updatedAt,
    required this.id,
  });
}

// TODO(未來 MEGA 接入): 實際後端為 MEGA（FFI 包官方 C++ SDK），本期不要引入任何網絡依賴。
// TODO(同步策略): Last-Write-Wins，比對 updatedAt；雙端同改同一篇時，
//   利用 history/ 快照按筆畫時間戳合併（本期僅留接口）。
