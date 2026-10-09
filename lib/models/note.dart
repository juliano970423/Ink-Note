import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset;

/// 單個採樣點。`p` 為當時算好的模擬壓感（0..1），重放渲染直接使用，不重算。
/// `t` 為該點相對筆畫起筆的毫秒偏移（int）。
class NotePoint {
  final double x;
  final double y;
  final double p;
  final int t;

  const NotePoint({required this.x, required this.y, required this.p, required this.t});

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'p': p, 't': t};

  factory NotePoint.fromJson(Map<String, dynamic> json) => NotePoint(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        p: (json['p'] as num).toDouble(),
        t: (json['t'] as num).toInt(),
      );
}

/// 一筆：同色、同粗細、同頁、同筆型的一串點。
class Stroke {
  final String color; // hex, e.g. "#000000"
  final double size;
  final List<NotePoint> points;
  /// 所在頁（0 起）。無限畫布恆為 0。
  final int page;
  /// 所在圖層（0 起，0 最底）。
  final int layer;
  /// 筆型（見 PenType，定義在 stroke_renderer.dart 以避循環依賴）。
  final String type;
  /// 不透明度（目前只有螢光筆用，筆刷/虛線恆 1）。
  final double alpha;
  /// 幾何筆（形狀修正產物：直線/圓/矩形）：點列是折線控制點，
  /// 渲染走普通描邊（不斷頭尾相接），不吃壓感輪廓（尖角折線會算壞）。
  final bool geometric;

  const Stroke({
    required this.color,
    required this.size,
    required this.points,
    this.page = 0,
    this.layer = 0,
    this.type = 'brush',
    this.alpha = 1.0,
    this.geometric = false,
  });

  Map<String, dynamic> toJson() => {
        'color': color,
        'size': size,
        'points': points.map((e) => e.toJson()).toList(),
        'page': page,
        'layer': layer,
        'type': type,
        'alpha': alpha,
        'geometric': geometric,
      };

  factory Stroke.fromJson(Map<String, dynamic> json) => Stroke(
        color: json['color'] as String,
        size: (json['size'] as num).toDouble(),
        points: (json['points'] as List)
            .map((e) => NotePoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        page: (json['page'] as num?)?.toInt() ?? 0,
        layer: (json['layer'] as num?)?.toInt() ?? 0,
        type: json['type'] as String? ?? 'brush',
        alpha: (json['alpha'] as num?)?.toDouble() ?? 1.0,
        // 舊文件無此欄位 → 預設手寫筆（向前相容）。
        geometric: json['geometric'] as bool? ?? false,
      );

  Stroke copyWith(
          {String? color,
          double? size,
          List<NotePoint>? points,
          int? page,
          int? layer,
          String? type,
          double? alpha,
          bool? geometric}) =>
      Stroke(
        color: color ?? this.color,
        size: size ?? this.size,
        points: points ?? this.points,
        page: page ?? this.page,
        layer: layer ?? this.layer,
        type: type ?? this.type,
        alpha: alpha ?? this.alpha,
        geometric: geometric ?? this.geometric,
      );

  /// 整筆平移（圈選移動用）。
  Stroke moved(Offset by) => Stroke(
        color: color,
        size: size,
        points: points
            .map((p) => NotePoint(
                x: p.x + by.dx, y: p.y + by.dy, p: p.p, t: p.t))
            .toList(),
        page: page,
        layer: layer,
        type: type,
        alpha: alpha,
        geometric: geometric,
      );

  /// 整筆繞 [center] 旋轉 [radians]（圈選旋轉用，壓感/時間戳保留）。
  Stroke rotated(Offset center, double radians) {
    final c = cos(radians), s = sin(radians);
    return Stroke(
      color: color,
      size: size,
      points: points
          .map((p) {
            final dx = p.x - center.dx, dy = p.y - center.dy;
            return NotePoint(
              x: center.dx + dx * c - dy * s,
              y: center.dy + dx * s + dy * c,
              p: p.p,
              t: p.t,
            );
          })
          .toList(),
      page: page,
      layer: layer,
      type: type,
      alpha: alpha,
      geometric: geometric,
    );
  }
}

/// 頁面尺寸（mm）。null 即無限畫布。
class PageSize {
  final String id;
  final String label;
  final double wMm;
  final double hMm;

  const PageSize(this.id, this.label, this.wMm, this.hMm);

  /// mm → 畫布 px（96dpi）。
  double get wPx => wMm * 96 / 25.4;
  double get hPx => hMm * 96 / 25.4;

  static const List<PageSize> all = [
    PageSize('A4', 'A4', 210, 297),
    PageSize('A5', 'A5', 148, 210),
    PageSize('B5', 'B5', 176, 250),
    PageSize('Letter', 'Letter', 215.9, 279.4),
  ];

  static PageSize? byId(String? id) {
    if (id == null) return null;
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// PDF 匯入底圖：每頁一張 PNG（存同目錄 `{basename}_bg{key}.png`），
/// 這裡只記渲染像素尺寸，顯示時等比縮到 800 內容 px 寬。
/// [key] 是底圖唯一鍵（排序/刪頁只改列表順序，不搬文件）；
/// [src] 是原 PDF 頁碼（向量匯出映射用；null = 後加的空白頁，無向量源）。
class PageBg {
  final int w;
  final int h;
  final String key;
  final int? src;

  const PageBg({required this.w, required this.h, this.key = '', this.src});

  Map<String, dynamic> toJson() => {
        'w': w,
        'h': h,
        if (key.isNotEmpty) 'key': key,
        if (src != null) 'src': src,
      };

  /// [index] 供舊文件補鍵用（舊文件無 key，讀出來給 `p{index}` 穩定鍵）。
  factory PageBg.fromJson(Map<String, dynamic> json, [int index = 0]) =>
      PageBg(
        w: (json['w'] as num).toInt(),
        h: (json['h'] as num).toInt(),
        key: json['key'] as String? ?? 'p$index',
        src: (json['src'] as num?)?.toInt(),
      );
}

class Note {
  static const int currentVersion = 1;

  final String id; // 4~6 位隨機 hex
  String title;
  DateTime createdAt;
  DateTime updatedAt;
  List<Stroke> strokes;
  /// 所屬資料夾（'' = 根目錄/未分類）。磁碟上為 notes/ 下的子目錄。
  String folder;
  /// 頁面尺寸 id（見 [PageSize]）；null = 無限畫布。
  String? pageId;
  /// 圖層名（下標 = 圖層 id，0 最底）。空 = 單圖層。
  List<String> layerNames;
  /// 隱藏的圖層 id。
  List<int> hiddenLayers;
  /// PDF 底圖（空 = 普通筆記）。下標 = 頁碼。
  List<PageBg> backgrounds;

  Note({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    List<Stroke>? strokes,
    this.folder = '',
    this.pageId,
    List<String>? layerNames,
    List<int>? hiddenLayers,
    List<PageBg>? backgrounds,
  })  : strokes = strokes ?? [],
        layerNames =
            layerNames ?? <String>['圖層 1'],
        hiddenLayers = hiddenLayers ?? <int>[],
        backgrounds = backgrounds ?? <PageBg>[];

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'id': id,
        'title': title,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'folder': folder,
        if (pageId != null) 'page': pageId,
        'layerNames': layerNames,
        'hiddenLayers': hiddenLayers,
        'backgrounds': backgrounds.map((e) => e.toJson()).toList(),
        'strokes': strokes.map((e) => e.toJson()).toList(),
      };

  factory Note.fromJson(Map<String, dynamic> json) {
    final strokes = (json['strokes'] as List? ?? [])
        .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
        .toList();
    final bgs = (json['backgrounds'] as List?)
            ?.asMap()
            .entries
            .map((e) => PageBg.fromJson(e.value as Map<String, dynamic>, e.key))
            .toList() ??
        <PageBg>[];
    // PDF 筆記：筆跡落在底圖列表之外的頁（舊版虛擬空白頁），補成真正的
    // 空白頁條目（鍵 `x{頁碼}` 穩定，尺寸套末頁），版式/匯出不再有特例。
    if (bgs.isNotEmpty) {
      var top = -1;
      for (final s in strokes) {
        if (s.page > top) top = s.page;
      }
      if (top >= bgs.length) {
        final last = bgs.last;
        for (var i = bgs.length; i <= top; i++) {
          bgs.add(PageBg(w: last.w, h: last.h, key: 'x$i'));
        }
      }
    }
    return Note(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      strokes: strokes,
      // 舊文件無此欄位 → 預設根目錄/無限畫布（向前相容，不升級 version）。
      folder: json['folder'] as String? ?? '',
      pageId: json['page'] as String?,
      layerNames: (json['layerNames'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>['圖層 1'],
      hiddenLayers: (json['hiddenLayers'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          <int>[],
      backgrounds: bgs,
    );
  }

  String encode() => jsonEncode(toJson());

  static Note decode(String source) =>
      Note.fromJson(jsonDecode(source) as Map<String, dynamic>);

  /// 生成 4~6 位隨機 hex id。
  static String newId([Random? random]) {
    final r = random ?? Random.secure();
    final len = 4 + r.nextInt(3); // 4,5,6
    final sb = StringBuffer();
    const hex = '0123456789abcdef';
    for (var i = 0; i < len; i++) {
      sb.write(hex[r.nextInt(16)]);
    }
    return sb.toString();
  }

  /// 過濾標題中的非法字符（Windows/posix 通用）。
  static String sanitizeTitle(String title) {
    var s = title.trim();
    // 非法字符: < > : " / \ | ? * 及控制字符
    s = s.replaceAll(RegExp(r'[<>:\"/\\|?*\x00-\x1f]'), '_');
    // Windows 不允許結尾空格/點
    s = s.replaceAll(RegExp(r'[ .]+$'), '');
    if (s.isEmpty) return 'untitled';
    if (s.length > 80) s = s.substring(0, 80);
    return s;
  }

  /// 資料夾名過濾（空字串 = 根目錄）。規則同標題，但保留空值。
  static String sanitizeFolder(String folder) {
    final t = folder.trim();
    if (t.isEmpty) return '';
    final s = sanitizeTitle(t);
    return s == 'untitled' ? '' : s;
  }

  /// 文件名：{yyyy-MM-dd}_{標題}_{id}.json
  String fileName({DateTime? date}) {
    final d = (date ?? updatedAt).toLocal();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-${day}_${sanitizeTitle(title)}_$id.json';
  }

  /// 同目錄縮圖文件名：把 .json 換成 .png
  String thumbnailName({DateTime? date}) =>
      fileName(date: date).replaceAll(RegExp(r'\.json$'), '.png');
}
