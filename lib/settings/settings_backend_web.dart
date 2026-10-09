/// Web 預覽用內存持久化（reload 不持久，僅供 UI/手感測試）。
/// TODO(Web 持久化): 改用 localStorage（package:web）以便刷新後恢復。
Map<String, dynamic>? _mem;

Future<Map<String, dynamic>?> loadSettingsMap() async => _mem;

Future<void> saveSettingsMap(Map<String, dynamic> json) async {
  _mem = Map<String, dynamic>.from(json);
}
