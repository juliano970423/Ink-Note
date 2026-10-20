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
  /// 落筆時凍結的渲染參數（null = 老筆記缺欄位，沿用當前設定；
  /// 非 null = 以存檔為準，換設備/改設定都不變）。
  /// thinning/streamline 進壓感輪廓，hlw 是螢光筆寬度倍數。
  final double? thinning;
  final double? streamline;
  final double? hlw;

  const Stroke({
    required this.color,
    required this.size,
    required this.points,
    this.page = 0,
    this.layer = 0,
    this.type = 'brush',
    this.alpha = 1.0,
    this.geometric = false,
    this.thinning,
    this.streamline,
    this.hlw,
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
        if (thinning != null) 'thinning': thinning,
        if (streamline != null) 'streamline': streamline,
        if (hlw != null) 'hlw': hlw,
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
        // 老筆記無凍結參數 → null，渲染時沿用當前設定。
        thinning: (json['thinning'] as num?)?.toDouble(),
        streamline: (json['streamline'] as num?)?.toDouble(),
        hlw: (json['hlw'] as num?)?.toDouble(),
      );

  Stroke copyWith(
          {String? color,
          double? size,
          List<NotePoint>? points,
          int? page,
          int? layer,
          String? type,
          double? alpha,
          bool? geometric,
          double? thinning,
          double? streamline,
          double? hlw}) =>
      Stroke(
        color: color ?? this.color,
        size: size ?? this.size,
        points: points ?? this.points,
        page: page ?? this.page,
        layer: layer ?? this.layer,
        type: type ?? this.type,
        alpha: alpha ?? this.alpha,
        geometric: geometric ?? this.geometric,
        thinning: thinning ?? this.thinning,
        streamline: streamline ?? this.streamline,
        hlw: hlw ?? this.hlw,
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
        thinning: thinning,
        streamline: streamline,
        hlw: hlw,
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
        thinning: thinning,
        streamline: streamline,
        hlw: hlw,
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

  factory PageBg.fromJson(Map<String, dynamic> json) => PageBg(
        w: (json['w'] as num).toInt(),
        h: (json['h'] as num).toInt(),
        key: json['key'] as String? ?? '',
        src: (json['src'] as num?)?.toInt(),
      );
}

/// 貼上/插入的圖片：頁內左上 (x, y)＋尺寸 (w, h)，PNG 存同目錄
/// `{basename}_img{id}.png`（見 NoteStore.saveImage）。
/// 顯示在 PDF 底圖之上；圖層與筆跡一起排（同層筆跡蓋圖，上層一切蓋下層一切，
/// 故圖能蓋住下面圖層的筆跡；橡皮/圈選筆跡不碰圖片，但圈選可框住圖片一起操作）。
class NoteImage {
  final String id; // Note.newId()，hex，檔名安全
  final int page; // 所在頁（0 起）
  final double x;
  final double y;
  final double w;
  final double h;
  /// 所在圖層（0 起，0 最底；與 Stroke.layer 同序）。
  final int layer;

  const NoteImage({
    required this.id,
    required this.page,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.layer = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'page': page,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'layer': layer,
      };

  factory NoteImage.fromJson(Map<String, dynamic> json) => NoteImage(
        id: json['id'] as String,
        page: (json['page'] as num?)?.toInt() ?? 0,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        w: (json['w'] as num).toDouble(),
        h: (json['h'] as num).toDouble(),
        layer: (json['layer'] as num?)?.toInt() ?? 0,
      );

  NoteImage copyWith(
          {String? id,
          int? page,
          double? x,
          double? y,
          double? w,
          double? h,
          int? layer}) =>
      NoteImage(
        id: id ?? this.id,
        page: page ?? this.page,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        layer: layer ?? this.layer,
      );

  /// 整圖平移（頁內座標）。
  NoteImage moved(Offset by) =>
      copyWith(x: x + by.dx, y: y + by.dy);

  /// 等比縮放（錨定左上，w/h 同比）。
  NoteImage scaled(double factor) =>
      copyWith(w: (w * factor).clamp(8, 4000), h: (h * factor).clamp(8, 4000));

  /// 命中測試（頁內座標）。
  bool contains(Offset p) =>
      p.dx >= x && p.dx <= x + w && p.dy >= y && p.dy <= y + h;
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
  /// 末尾空白頁數（紙筆記的隱式頁：頁面只在有筆跡/圖片時才落資料）。
  /// PDF 筆記的空白尾頁是真的 PageBg，這裡恆為 0。
  int extraPages;
  /// 圖層名（下標 = 圖層 id，0 最底）。空 = 單圖層。
  List<String> layerNames;
  /// 隱藏的圖層 id。
  List<int> hiddenLayers;
  /// PDF 底圖（空 = 普通筆記）。下標 = 頁碼。
  List<PageBg> backgrounds;
  /// 貼上/插入的圖片（空 = 無）。PNG 另存（見 NoteStore.saveImage），
  /// 這裡只記頁碼＋頁內位置尺寸。
  List<NoteImage> images;

  Note({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    List<Stroke>? strokes,
    this.folder = '',
    this.pageId,
    this.extraPages = 0,
    List<String>? layerNames,
    List<int>? hiddenLayers,
    List<PageBg>? backgrounds,
    List<NoteImage>? images,
  })  : strokes = strokes ?? [],
        layerNames =
            layerNames ?? <String>['圖層 1'],
        hiddenLayers = hiddenLayers ?? <int>[],
        backgrounds = backgrounds ?? <PageBg>[],
        images = images ?? <NoteImage>[];

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'id': id,
        'title': title,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'folder': folder,
        if (pageId != null) 'page': pageId,
        if (extraPages > 0) 'extraPages': extraPages,
        'layerNames': layerNames,
        'hiddenLayers': hiddenLayers,
        'backgrounds': backgrounds.map((e) => e.toJson()).toList(),
        'images': images.map((e) => e.toJson()).toList(),
        'strokes': strokes.map((e) => e.toJson()).toList(),
      };

  factory Note.fromJson(Map<String, dynamic> json) {
    final strokes = (json['strokes'] as List? ?? [])
        .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
        .toList();
    final images = (json['images'] as List?)
            ?.map((e) => NoteImage.fromJson(e as Map<String, dynamic>))
            .toList() ??
        <NoteImage>[];
    final bgs = (json['backgrounds'] as List? ?? [])
        .map((e) => PageBg.fromJson(e as Map<String, dynamic>))
        .toList();
    // PDF 筆記：筆跡/圖片落在底圖列表之外的頁（舊版虛擬空白頁），補成真正的
    // 空白頁條目（鍵 `x{頁碼}` 穩定，尺寸套末頁），版式/匯出不再有特例。
    if (bgs.isNotEmpty) {
      var top = -1;
      for (final s in strokes) {
        if (s.page > top) top = s.page;
      }
      for (final m in images) {
        if (m.page > top) top = m.page;
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
      extraPages: ((json['extraPages'] as num?)?.toInt() ?? 0).clamp(0, 100000),
      images: images,
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
