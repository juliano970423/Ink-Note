import '../ink/velocity_tracker.dart';
import 'settings_backend_default.dart'
    if (dart.library.io) 'settings_backend_io.dart'
    if (dart.library.js_interop) 'settings_backend_web.dart';

/// 設置頁兩項設備相關設置（存本地 JSON）：
/// - perDeviceProfile: { maxSpeed, emaWeight } 各設備採樣率 60~240Hz 手感微調
/// - palmRejection: 開啟時僅接受 stylus/inverted/mouse 輸入
/// 持久化走條件導入：桌面/移動端存文件，Web 存內存（reload 不持久）。
/// 快捷筆預設：色 + 筆型 + 粗細（工具欄一鍵切換，長按存入當前筆）。
class PenPreset {
  String color;
  String type;
  double size;

  PenPreset({required this.color, required this.type, required this.size});

  Map<String, dynamic> toJson() =>
      {'color': color, 'type': type, 'size': size};

  factory PenPreset.fromJson(Map<String, dynamic> json) => PenPreset(
        color: json['color'] as String? ?? '#000000',
        type: json['type'] as String? ?? 'brush',
        size: (json['size'] as num?)?.toDouble() ?? 4.0,
      );
}

class AppSettings {
  static List<PenPreset> get defaultQuickPens => [
        PenPreset(color: '#000000', type: 'brush', size: 4.0),
        PenPreset(color: '#d32f2f', type: 'brush', size: 4.0),
        PenPreset(color: '#1565c0', type: 'highlighter', size: 4.0),
      ];

  static const List<String> defaultPens = [
    '#000000', '#434343', '#666666', '#999999', '#b7b7b7',
    '#d32f2f', '#e8710a', '#f9ab00', '#ffd600', '#188038',
    '#20c997', '#1565c0', '#00bcd4', '#5e35b1', '#c2185b',
    '#795548', '#ff8a80', '#ffab40', '#aeea00', '#69f0ae',
  ];

  StrokeParams deviceProfile;
  bool palmRejection;
  List<String> penColors;
  String lastColor;
  double lastSize;
  String lastPenType;
  double lastHlAlpha;
  double lastHlWidth;
  bool shapeSnap;
  List<PenPreset> quickPens;
  bool readOnly;
  double pixelEraserSize;
  double strokeEraserSize;
  bool _loaded = false;

  AppSettings({
    StrokeParams? deviceProfile,
    this.palmRejection = false,
    List<String>? penColors,
    this.lastColor = '#000000',
    this.lastSize = 4.0,
    this.lastPenType = 'brush',
    this.lastHlAlpha = 0.35,
    this.lastHlWidth = 3.0,
    this.shapeSnap = true,
    List<PenPreset>? quickPens,
    this.readOnly = false,
    this.pixelEraserSize = 12.0,
    this.strokeEraserSize = 12.0,
  })  : deviceProfile = deviceProfile ?? StrokeParams(),
        penColors = penColors ?? List<String>.from(defaultPens),
        quickPens = quickPens ?? defaultQuickPens;

  Future<void> load() async {
    try {
      final json = await loadSettingsMap();
      if (json != null) {
        if (json['deviceProfile'] is Map) {
          deviceProfile = StrokeParams.fromJson(
              (json['deviceProfile'] as Map).cast<String, dynamic>());
        }
        palmRejection = json['palmRejection'] == true;
        final pens = json['penColors'];
        if (pens is List && pens.isNotEmpty) {
          penColors = pens.whereType<String>().toList();
        }
        final c = json['lastColor'];
        if (c is String && c.isNotEmpty) lastColor = c;
        final s = json['lastSize'];
        if (s is num) lastSize = s.toDouble();
        final pt = json['lastPenType'];
        if (pt is String && pt.isNotEmpty) lastPenType = pt;
        final ha = json['lastHlAlpha'];
        if (ha is num) lastHlAlpha = ha.toDouble().clamp(0.05, 1.0);
        final hw = json['lastHlWidth'];
        if (hw is num) lastHlWidth = hw.toDouble().clamp(2.0, 6.0);
        final ss = json['shapeSnap'];
        if (ss is bool) shapeSnap = ss;
        final qp = json['quickPens'];
        if (qp is List && qp.isNotEmpty) {
          quickPens = qp
              .whereType<Map>()
              .map((m) => PenPreset.fromJson(
                  m.map((k, v) => MapEntry(k.toString(), v))))
              .toList();
        }
        final ro = json['readOnly'];
        if (ro is bool) readOnly = ro;
        final px = json['pixelEraserSize'];
        if (px is num) pixelEraserSize = px.toDouble();
        final st = json['strokeEraserSize'];
        if (st is num) strokeEraserSize = st.toDouble();
      }
    } catch (_) {}
    _loaded = true;
  }

  Future<void> save() async {
    await saveSettingsMap({
      'deviceProfile': deviceProfile.toJson(),
      'palmRejection': palmRejection,
      'penColors': penColors,
      'lastColor': lastColor,
      'lastSize': lastSize,
      'lastPenType': lastPenType,
      'lastHlAlpha': lastHlAlpha,
      'lastHlWidth': lastHlWidth,
      'shapeSnap': shapeSnap,
      'quickPens': quickPens.map((p) => p.toJson()).toList(),
      'readOnly': readOnly,
      'pixelEraserSize': pixelEraserSize,
      'strokeEraserSize': strokeEraserSize,
    });
  }

  bool get isLoaded => _loaded;
}
