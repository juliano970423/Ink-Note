/// 兜底：未知平台直接報錯（不應到達）。
Future<Map<String, dynamic>?> loadSettingsMap() =>
    throw UnsupportedError('no settings backend for this platform');

Future<void> saveSettingsMap(Map<String, dynamic> json) =>
    throw UnsupportedError('no settings backend for this platform');
