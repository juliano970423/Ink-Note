import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../ink/stroke_renderer.dart';
import '../ink/velocity_tracker.dart' as ink;
import '../models/note.dart';

/// 手寫畫布：用 [Listener] 採集 onPointerDown/Move/Up（不用 GestureDetector）。
/// 時間戳用 event.timeStamp；忽略 event.pressure；滑鼠完整可用。
/// - [strokes] 傳整筆記（引用保持穩定）。
/// - 紙筆記多頁垂直堆疊（[pageRects] 為堆疊座標紙框，空 = 無限畫布）：
///   筆跡存的是頁內座標（第 0 頁恆等），畫布負責堆疊互轉，落筆頁由 y 歸屬。
/// - 有紙時書寫點鉗制在所屬頁內，橡皮/圈選可跨頁（落筆頁歸屬）。
/// - 平移：滾輪 / 雙指拖 / 右鍵拖；縮放：雙指捏合 / 觸控板捏合。
///   平移縮放不受 palmRejection 限制（導航自由）。
/// - 畫面關係：screen = stacked * scale + pan。
class InkCanvas extends StatefulWidget {
  final List<Stroke> strokes;
  final ink.StrokeParams params;
  final String color;
  final double size;
  final PenType penType;
  final ToolMode tool;
  final bool palmRejection;
  /// 收筆回調：[dwellMs] 為真實停頓（抬起 - 末個真移動，毫秒），形狀修正只認這個。
  final void Function(Stroke stroke, int dwellMs) onStrokeCompleted;
  /// 按筆畫橡皮：碰到即刪——按下/移動就回調 ([chunk], [page])（頁內座標，已按 4px 加密），
  /// 上層刪掉該頁命中筆跡；抬起時調 [onStrokeEraseEnd] 結算（只存檔一次）。
  /// 整個拖抹只算一次 undo（上層會話首刪時 checkpoint）。
  final void Function(List<Offset> chunk, int page) onStrokeEraseTick;
  final VoidCallback onStrokeEraseEnd;
  /// 像素橡皮：拖動中按段即刪——按下/移動就回調 ([chunk], [page])（頁內座標），
  /// 上層沿路徑抹除並斷筆；抬起時調 [onPixelEraseEnd] 結算（只存檔一次）。
  /// 整個拖抹只算一次 undo（上層會話首刪時 checkpoint）。
  final void Function(List<Offset> chunk, int page) onPixelEraseTick;
  final VoidCallback onPixelEraseEnd;
  final Offset panOffset;
  final double scale;
  final void Function(Offset delta) onPanUpdate;
  final void Function(double factor, Offset focal) onZoomUpdate;
  /// 縮放手勢結束（雙指抬起/觸控板捏合停手）：編輯器按需提底圖清晰度。
  final VoidCallback? onZoomEnd;
  /// 雙指縱向快掃翻頁（+1 下一頁 / -1 上一頁），慢速雙指仍是平移。
  final void Function(int dir) onPageFlick;
  /// 雙指點按：兩根手指連點兩下 → undo，三下 → redo。
  /// 輕觸（位移 <14px、按下到雙指都抬起 <400ms）才算點按，移動/久按不觸發。
  final VoidCallback onTwoFingerDoubleTap;
  final VoidCallback onTwoFingerTripleTap;
  /// 唯讀：一切單指/滑鼠/筆輸入都變平移（查看模式）。
  final bool readOnly;
  /// 形狀修正開關（關了就不預覽不修正）。
  final bool shapeSnap;
  final void Function(List<Offset> loop, int page) onLassoCompleted;
  final void Function(Offset delta) onSelectionMove;
  /// 圈選旋轉：手柄拖動的角度增量（繞堆疊座標 [center]），與移動同一個 undo 作用域。
  final void Function(double dAngle, Offset center) onSelectionRotate;
  /// 拖移結束（抬起）：此時才把出紙部分裁掉（拖曳中途只路過不算）。
  final VoidCallback onSelectionEnd;
  final VoidCallback onDeselect;
  final Rect? selectionBounds;
  /// 選區所在頁（[selectionBounds] 為該頁頁內座標）。
  final int selectionPage;
  /// 選中物件的虛線框（堆疊座標，包圍盒外擴）。
  final Rect? selectionRect;
  /// 紙框（堆疊座標，多頁垂直連排；空 = 無限畫布）。僅視覺底 + 書寫鉗制。
  final List<Rect> pageRects;
  /// 隱藏的圖層 id（不畫、不命中）。
  final List<int> hiddenLayers;
  /// 貼圖：meta 列表（構造參數，editor setState 更新）＋解碼圖
  /// （setNoteImages imperative＋clone 自持，仿底圖）。
  /// 按圖層烘進快取（同層筆跡蓋圖，上層一切蓋下層一切）。
  /// 交互（筆工具下，僅觸控筆/滑鼠；手指永遠直接畫線）：
  /// 點圖選中，已選中圖上拖動＝移動，右下手柄拖＝等比縮放，
  /// 點空白取消；想在圖上畫線先點空白取消選中。
  final List<NoteImage> images;
  final void Function(String? id) onImageSelected;
  final VoidCallback onImageDragStart;
  final void Function(String id, double x, double y, double w, double h)
      onImageChanged;
  final VoidCallback onImageDragEnd;
  /// 圈選中的圖片 ids（editor 持有，只畫框；拖動只認內部單選）。
  final Set<String> selectedImageIds;
  /// 像素橡皮半徑 / 按筆畫橡皮命中閾值 / 螢光筆寬度倍數與透明度。
  final double pixelRadius;
  final double strokeThreshold;
  final double hlWidth;
  final double hlAlpha;

  const InkCanvas({
    super.key,
    required this.strokes,
    required this.params,
    required this.color,
    required this.size,
    required this.penType,
    required this.tool,
    required this.palmRejection,
    required this.onStrokeCompleted,
    required this.onStrokeEraseTick,
    required this.onStrokeEraseEnd,
    required this.onPixelEraseTick,
    required this.onPixelEraseEnd,
    this.images = const [],
    required this.onImageSelected,
    required this.onImageDragStart,
    required this.onImageChanged,
    required this.onImageDragEnd,
    this.selectedImageIds = const {},
    required this.panOffset,
    required this.scale,
    required this.onPanUpdate,
    required this.onZoomUpdate,
    this.onZoomEnd,
    required this.onPageFlick,
    required this.onTwoFingerDoubleTap,
    required this.onTwoFingerTripleTap,
    this.readOnly = false,
    this.shapeSnap = true,
    required this.onLassoCompleted,
    required this.onSelectionMove,
    required this.onSelectionRotate,
    required this.onSelectionEnd,
    required this.onDeselect,
    this.selectionBounds,
    this.selectionPage = 0,
    this.selectionRect,
    this.pageRects = const [],
    this.hiddenLayers = const [],
    this.pixelRadius = 12.0,
    this.strokeThreshold = 12.0,
    this.hlWidth = 3.0,
    this.hlAlpha = 0.35,
  });

  @override
  State<InkCanvas> createState() => InkCanvasState();
}

class InkCanvasState extends State<InkCanvas> {
  LiveStroke? _live;
  ink.VelocityTracker _tracker = ink.VelocityTracker();
  List<Offset> _liveOutline = [];
  ui.Picture? _completedPicture;
  // 底圖層（筆跡層之下；分層渲染，互不擋）
  ui.Picture? _bgPicture;
  Duration _lastOutlineAt = Duration.zero;

  // 平移/縮放手勢狀態
  final Map<int, Offset> _active = {};
  final Map<int, PointerDeviceKind> _kinds = {};
  final Map<int, Duration> _seen = {};
  bool _twoFinger = false;
  bool _blockUntilLift = false;
  Offset? _rightPanLast;
  Offset? _twoStartMid;
  Duration? _twoStartTime;
  // 單指平移（唯讀模式 / 防誤觸下的觸屏）
  Offset? _singlePanLast;

  /// 該指針是否參與手勢計數。觸屏永遠計數（雙指縮放/單指平移自由，
  /// 防誤觸只管「落筆」，不管導航）；手掌誤放由落筆處的手掌保護擋，
  /// 不進雙指、不搶書寫。
  bool _triggersGesture(PointerDeviceKind kind) {
    return true;
  }

  /// 手掌闖入：防誤觸開、觸屏事件、且有別人的非觸屏書寫會話在進行。
  /// 手掌的落下/抬起不碰書寫會話（不停頓計時、不清 _live）。
  bool _isPalmIntrusion(PointerEvent e) {
    if (!widget.palmRejection) return false;
    if (e.kind != PointerDeviceKind.touch) return false;
    if (_live == null || _primary == null) return false;
    return _kinds[_primary] != PointerDeviceKind.touch;
  }

  int _gestureCount() {
    var n = 0;
    for (final entry in _active.entries) {
      final k = _kinds[entry.key];
      if (k != null && _triggersGesture(k)) n++;
    }
    return n;
  }

  /// 丟失 up 的陳舊指針（>10s 無事件）清掉，防狀態卡死。
  void _purgeStale(Duration now) {
    final dead = <int>[];
    _seen.forEach((id, t) {
      if ((now - t).inMicroseconds > 10 * 1000000) dead.add(id);
    });
    for (final id in dead) {
      _active.remove(id);
      _kinds.remove(id);
      _seen.remove(id);
    }
    if (_active.isEmpty) {
      _blockUntilLift = false;
      _twoFinger = false;
    }
  }
  // 圈選狀態（_lassoPath 與選區 loop 皆為堆疊座標；選區 bounds 為選區頁內座標）
  List<Offset> _lassoPath = [];
  bool _movingSel = false;
  bool _rotating = false;
  Offset? _rotateCenter;
  double _rotateLastAng = 0;
  Offset? _lastLocal;
  // PDF 底圖（編輯器推送解碼好的圖，畫布 clone 自持，畫進快取最底層）
  Map<int, ui.Image> _bgImgs = {};
  // 貼圖解碼圖（id → 圖；clone 自持＋隔代釋放，仿底圖）
  Map<String, ui.Image> _noteImgs = {};
  Map<String, ui.Image> _retiredNoteImgs = {};
  // 圖片選中/拖動：選中 id、拖動所屬指針、是否手柄縮放、上次屏位置、
  // 本次拖動是否已通知上層（首動才 checkpoint，純點選不留空 undo）
  String? _selectedImageId;
  int? _imgDragPointer;
  bool _imgResizing = false;
  Offset? _imgDragLast;
  bool _imgDragStarted = false;
  // 取消點待定：有圖選中時筆點圖外，先取消選中；抬起時沒畫出東西
  // 就不提交（只取消，不多一筆點筆）；真畫了就正常落筆。
  int? _deselectTapArmed;
  // 上一代底圖 clone（隔代釋放，見 setBgImages）
  Map<int, ui.Image> _retiredBgImgs = {};
  // 橡皮會話：拖動中只累路徑+畫游標，放開才提交
  List<Offset> _erasePath = [];
  bool _erasing = false;
  // 當前書寫/擦除/圈選/平移會話所屬指針（防多指串擾）
  int? _primary;
  // 停頓預覽：按住 1s 不動，藏起原軌跡、顯示預計修正形狀
  Timer? _dwellTimer;
  List<Stroke>? _snapPreview;
  // 停頓錨點：上個真移動的位置＋時刻。筆靜止噪聲/按住手抖
  // 推不動錨點（停頓照算）；小字慢寫的點全收保形（只去重疊點）。
  Offset _dwellAnchor = Offset.zero;
  Duration _dwellAnchorTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    _tracker = ink.VelocityTracker(emaWeight: widget.params.emaWeight);
    _scheduleCompletedRebuild();
  }

  @override
  void didUpdateWidget(InkCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.shapeSnap) _cancelDwell();
    if (widget.params.emaWeight != _tracker.emaWeight) {
      _tracker.emaWeight = widget.params.emaWeight;
    }
    // 參數/筆畫/頁數/螢光寬度變化 → 清快取重建（平移縮放只改 transform，不重建）
    if (widget.strokes.length != oldWidget.strokes.length ||
        widget.pageRects.length != oldWidget.pageRects.length ||
        widget.hlWidth != oldWidget.hlWidth ||
        widget.params.thinning != oldWidget.params.thinning ||
        widget.params.streamline != oldWidget.params.streamline ||
        widget.params.size != oldWidget.params.size ||
        !identical(widget.strokes, oldWidget.strokes)) {
      _scheduleCompletedRebuild();
    }
  }

  /// 外部筆畫/參數/頁碼變化後調用：後台重建、好了才換（無閃白）。
  void invalidateCache() {
    _scheduleCompletedRebuild();
  }

  /// 底圖推送（編輯器解碼好後調用，順手重建）。
  /// 畫布 clone 一份自己持有：編輯器隨後 dispose/重載不影響正在畫的重建
  ///（頁面排序/增刪時舊圖被 dispose，這裡曾畫出已釋放的圖而報錯）。
  /// 舊 clone 隔代釋放（retired 留到下一次替換才 dispose），保證
  /// 在飛的重建 paint 讀到的圖一定還活著。
  void setBgImages(Map<int, ui.Image> images) {
    for (final v in _retiredBgImgs.values) {
      v.dispose();
    }
    _retiredBgImgs = _bgImgs;
    _bgImgs = {for (final e in images.entries) e.key: e.value.clone()};
    _scheduleCompletedRebuild();
  }

  /// 貼圖推送（editor 解碼好後調用；圖片走即時層，每幀現畫，
  /// 拖動跟手，不進快取，故只 setState 不重建）。
  void setNoteImages(Map<String, ui.Image> images) {
    for (final v in _retiredNoteImgs.values) {
      v.dispose();
    }
    _retiredNoteImgs = _noteImgs;
    _noteImgs = {for (final e in images.entries) e.key: e.value.clone()};
    // 選中圖若已不在列表（被刪），順手清選中
    if (_selectedImageId != null &&
        !widget.images.any((m) => m.id == _selectedImageId)) {
      _selectedImageId = null;
      _imgDragPointer = null;
      _imgDragLast = null;
      widget.onImageSelected(null);
    }
    if (mounted) setState(() {});
  }

  /// 頁內座標 → 堆疊座標（無限畫布恆等；有紙按頁頂偏移）。
  Offset _stackedOfLocal(Offset local, int page) {
    if (widget.pageRects.isEmpty) return local;
    if (page < 0 || page >= widget.pageRects.length) return local;
    return local + Offset(0, widget.pageRects[page].top - 24);
  }

  /// 已選中的圖 meta（不在列表就 null）。
  NoteImage? _selectedMeta() {
    final id = _selectedImageId;
    if (id == null) return null;
    for (final m in widget.images) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 命中圖片（堆疊座標；倒序，頂層優先；越界頁/隱藏層跳過）。
  String? _hitImage(Offset stacked) {
    for (var i = widget.images.length - 1; i >= 0; i--) {
      final m = widget.images[i];
      if (m.page < 0 ||
          (widget.pageRects.isNotEmpty &&
              m.page >= widget.pageRects.length)) {
        continue;
      }
      if (widget.hiddenLayers.contains(m.layer)) continue;
      if (m.contains(_localOf(stacked, m.page))) return m.id;
    }
    return null;
  }

  /// 已選中圖的右下縮放手柄（堆疊座標）。
  Offset? _imgHandleStacked() {
    final m = _selectedMeta();
    if (m == null) return null;
    return _stackedOfLocal(Offset(m.x + m.w, m.y + m.h), m.page);
  }

  void _selectImage(String? id) {
    if (_selectedImageId == id) return;
    _selectedImageId = id;
    _imgDragPointer = null;
    _imgResizing = false;
    _imgDragLast = null;
    _imgDragStarted = false;
    widget.onImageSelected(id);
    if (mounted) setState(() {});
  }

  /// 對外清圖片選中（操作條取消鈕用；up 路徑點空白已自行處理）。
  void deselectImage() => _selectImage(null);

  void _cancelDwell() {
    _dwellTimer?.cancel();
    _dwellTimer = null;
    if (_snapPreview != null) {
      _snapPreview = null;
      if (mounted) setState(() {});
    }
  }

  void _armDwell() {
    _dwellTimer?.cancel();
    _dwellTimer = null;
    if (_snapPreview != null) {
      _snapPreview = null;
      if (mounted) setState(() {});
    }
    // 最後一個點之後 1050ms 沒新點 = 按住停頓滿 1s
    _dwellTimer = Timer(const Duration(milliseconds: 1050), () {
      final live = _live;
      if (!mounted ||
          live == null ||
          !widget.shapeSnap ||
          live.penType != PenType.brush ||
          live.positions.length < 8) {
        return;
      }
      final raw = live.toStroke();
      final preview = snapShape(raw, dwellMs: 1100);
      if (preview.length == 1 && identical(preview.first, raw)) {
        return; // 沒修正就不擋原軌跡
      }
      if (mounted) {
        setState(() => _snapPreview = preview);
      }
    });
  }

  int _picGen = 0;

  void _scheduleCompletedRebuild() async {
    // 雙緩衝 + 分層：底圖一張、筆跡一張，好了才一起換（無閃白）；
    // 筆跡層疊在底圖層上（螢光筆「字下面」需求已收回，標準半透明蓋字）。
    final gen = ++_picGen;
    ui.Picture? bgPic;
    ui.Picture pic;
    if (widget.pageRects.isEmpty) {
      final strokes = widget.strokes
          .where((s) => !widget.hiddenLayers.contains(s.layer))
          .toList();
      pic = await paintStrokesToPicture(strokes,
          hlWidth: widget.hlWidth,
          params: widget.params,
          images: widget.images,
          noteImages: _noteImgs,
          hiddenLayers: widget.hiddenLayers);
    } else {
      final groups = <PageLayer, List<Stroke>>{};
      for (final s in widget.strokes) {
        if (widget.hiddenLayers.contains(s.layer)) continue;
        (groups[(page: s.page, layer: s.layer)] ??= []).add(s);
      }
      Offset origin(int page) {
        if (page < 0 || page >= widget.pageRects.length) return Offset.zero;
        return Offset(0, widget.pageRects[page].top - 24);
      }
      Rect? bgRectOf(int p) => (p >= 0 && p < widget.pageRects.length)
          ? widget.pageRects[p]
          : null;

      bgPic = await paintBgToPicture(
          backgrounds: _bgImgs, bgRectOf: bgRectOf);
      if (!mounted || gen != _picGen) {
        bgPic.dispose();
        return;
      }
      pic = await paintPagesToPicture(groups, origin,
          hlWidth: widget.hlWidth,
          params: widget.params,
          images: widget.images,
          noteImages: _noteImgs,
          hiddenLayers: widget.hiddenLayers,
          includeBackgrounds: false);
    }
    if (!mounted || gen != _picGen) {
      bgPic?.dispose();
      pic.dispose();
      return;
    }
    setState(() {
      _bgPicture?.dispose();
      _bgPicture = bgPic;
      _completedPicture?.dispose();
      _completedPicture = pic;
    });
  }

  bool _acceptKind(PointerDeviceKind kind) {
    if (!widget.palmRejection) return true;
    // 開啟手掌誤觸拒絕：僅接受 stylus / invertedStylus / mouse
    return kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus ||
        kind == PointerDeviceKind.mouse;
  }

  Offset _content(Offset local) =>
      (local - widget.panOffset) / widget.scale;

  bool get _stacked => widget.pageRects.isNotEmpty;

  /// 堆疊 y 歸屬頁（無限畫布恆 0）。
  int _pageOfY(double y) {
    if (!_stacked) return 0;
    return pageFromY(y, widget.pageRects)
        .clamp(0, widget.pageRects.length - 1);
  }

  /// 堆疊座標 → 該頁頁內座標。
  Offset _localOf(Offset stacked, int page) {
    if (!_stacked) return stacked;
    return pageLocalOf(stacked, widget.pageRects[page]);
  }

  /// 書寫點鉗制在所屬頁內（無限畫布不過濾）。
  Offset _clampLocal(Offset p, int page) {
    if (!_stacked) return p;
    final r = widget.pageRects[page];
    return Offset(
      p.dx.clamp(24.0, 24 + r.width),
      p.dy.clamp(24.0, 24 + r.height),
    );
  }

  /// 選區 bounds（頁內）→ 堆疊座標（命中/手柄用）。
  Rect? _stackedBounds() {
    final b = widget.selectionBounds;
    if (b == null) return null;
    if (!_stacked) return b;
    if (widget.selectionPage < 0 ||
        widget.selectionPage >= widget.pageRects.length) {
      return b;
    }
    return b.shift(
        Offset(0, widget.pageRects[widget.selectionPage].top - 24));
  }

  /// 旋轉手柄位置（堆疊座標）：平時吸附選區底部正中；
  /// 轉動中跟著內容一起繞中心公轉（角度累加同一份 dAngle）。
  double? _handleAng;
  double _handleDist = 0;

  Offset? _rotateHandle() {
    final b = _stackedBounds();
    if (b == null) return null;
    if (!_rotating) {
      _handleAng = math.pi / 2;
      _handleDist = b.height / 2 + 44 / widget.scale;
    }
    final ang = _handleAng ?? math.pi / 2;
    return b.center + Offset(math.cos(ang), math.sin(ang)) * _handleDist;
  }

  double _angleOf(Offset p, Offset c) =>
      math.atan2(p.dy - c.dy, p.dx - c.dx);

  void _track(int pointer, Offset pos, PointerDeviceKind kind, Duration t) {
    _active[pointer] = pos;
    _kinds[pointer] = kind;
    _seen[pointer] = t;
  }

  void _untrack(int pointer) {
    _active.remove(pointer);
    _kinds.remove(pointer);
    _seen.remove(pointer);
  }

  void _onDown(PointerDownEvent e) {
    // 手掌落下不取消筆的停頓計時（書寫會話還在繼續）
    if (!_isPalmIntrusion(e)) _cancelDwell();
    _purgeStale(e.timeStamp);
    // 右鍵拖拽平移（桌面端），任何工具下都可用
    if (e.buttons & kSecondaryMouseButton != 0) {
      _track(e.pointer, e.localPosition, e.kind, e.timeStamp);
      _rightPanLast = e.localPosition;
      _singlePanLast = null;
      _live = null;
      _lassoPath = [];
      return;
    }
    _track(e.pointer, e.localPosition, e.kind, e.timeStamp);
    // 雙指點按追蹤（原始觸屏計數）：恰兩指落下開表，三指以上取消
    final touchesDown = _touchCount();
    if (touchesDown == 2) {
      _twoTapDownTime = e.timeStamp;
      _twoTapDownMid = _touchMid();
      _twoTapMoved = false;
    } else if (touchesDown > 2) {
      _twoTapDownTime = null;
      _twoTapDownMid = null;
    }
    // 第二指按下 → 轉雙指平移/縮放，作廢進行中的筆畫與圈選路徑；
    // 但筆書寫中後落的手指是手掌：已 track（防 stale），不轉雙指不作廢
    if (_gestureCount() >= 2) {
      if (_isPalmIntrusion(e)) return;
      _twoFinger = true;
      _twoStartMid = _midpoint();
      _twoStartTime = e.timeStamp;
      _live = null;
      _lassoPath = [];
      _movingSel = false;
      _rotating = false;
      _singlePanLast = null;
      // 雙指打斷圖片拖（選中保留，只停跟手；殘留會話順手結算）
      _imgDragPointer = null;
      _imgResizing = false;
      _imgDragLast = null;
      if (_imgDragStarted) {
        _imgDragStarted = false;
        widget.onImageDragEnd();
      }
      setState(() => _liveOutline = []);
      return;
    }
    if (_blockUntilLift) return;
    // 圈選工具：筆/滑鼠照常圈；防誤觸開時手指不圈（改單指平移，
    // 否則手掌誤放滿屏亂圈，與筆工具規則一致）
    if (widget.tool == ToolMode.lasso) {
      if (widget.palmRejection && e.kind == PointerDeviceKind.touch) {
        _singlePanLast = e.localPosition;
        _primary = e.pointer;
        _live = null;
        return;
      }
      final pos = _content(e.localPosition);
      // 旋轉手柄優先：抓住就進旋轉，不移動不重圈
      final handle = _rotateHandle();
      if (handle != null &&
          (pos - handle).distance <= 22 / widget.scale) {
        _rotating = true;
        _rotateCenter = _stackedBounds()!.center;
        _rotateLastAng = _angleOf(pos, _rotateCenter!);
        _primary = e.pointer;
        return;
      }
      // 已選中圖的右下手柄→等比縮放（手柄壓在選區角上，比選區移動優先）
      final sel = _selectedMeta();
      if (sel != null) {
        final h = _imgHandleStacked();
        if (h != null && (pos - h).distance <= 22 / widget.scale) {
          _imgDragPointer = e.pointer;
          _imgResizing = true;
          _imgDragLast = e.localPosition;
          _imgDragStarted = false;
          _primary = e.pointer;
          return;
        }
      }
      final bounds = _stackedBounds();
      // 膨脹命中區：零高度/細長選區也抓得起來
      if (bounds != null &&
          bounds.inflate(12 / widget.scale).contains(pos)) {
        _movingSel = true;
        _lastLocal = e.localPosition;
      } else {
        // 點中未選中的圖→選中＋跟手拖；空白→取消選中＋開新圈選路徑。
        // （筆工具永遠畫線不碰圖片；圖片點選/拖動/縮放只在圈選工具下。）
        final hit = _hitImage(pos);
        if (hit != null) {
          if (_selectedImageId != hit) _selectImage(hit);
          _imgDragPointer = e.pointer;
          _imgResizing = false;
          _imgDragLast = e.localPosition;
          _imgDragStarted = false;
          _primary = e.pointer;
          return;
        }
        // 空白：本地點選＋圈選選中的圖一起清（onDeselect 只清上層），
        // 筆跡選區由上層 _deselect 處理；本次落筆開新圈選路徑。
        if (_selectedImageId != null) {
          _selectImage(null);
        } else if (widget.selectedImageIds.isNotEmpty) {
          widget.onImageSelected(null);
        }
        widget.onDeselect();
        _lassoPath = [pos];
      }
      _primary = e.pointer;
      return;
    }
    // 單指平移：唯讀模式（任意設備）或防誤觸下的觸屏（筆負責畫）
    if (widget.readOnly ||
        (widget.palmRejection && e.kind == PointerDeviceKind.touch)) {
      _singlePanLast = e.localPosition;
      _primary = e.pointer;
      _live = null;
      return;
    }
    if (!_acceptKind(e.kind)) return;
    final stacked = _content(e.localPosition);
    // 有圖選中時（剛插入/點選/圈選）：筆/滑鼠落在選中圖內或其手柄上，
    // 筆和橡皮都不畫/不擦，直接拖圖/縮放——剛丟進去的圖任何工具都能擺。
    // 落在外：取消圖選中；筆點空且沒畫出東西就不留點（只取消）。
    // 無選中：筆落在圖上也是畫（描圖/標註），不選圖；選圖只在圈選工具下。
    // （手指永遠走各自的分流：畫線/圈選/平移，不碰這一套。）
    if (e.kind != PointerDeviceKind.touch &&
        (_selectedImageId != null || widget.selectedImageIds.isNotEmpty)) {
      final selLocal = _selectedMeta();
      if (selLocal != null) {
        final h = _imgHandleStacked();
        if (h != null && (stacked - h).distance <= 22 / widget.scale) {
          _imgDragPointer = e.pointer;
          _imgResizing = true;
          _imgDragLast = e.localPosition;
          _imgDragStarted = false;
          _primary = e.pointer;
          return;
        }
      }
      final hit = _hitImage(stacked);
      if (hit != null &&
          (hit == _selectedImageId ||
              widget.selectedImageIds.contains(hit))) {
        if (_selectedImageId != hit) _selectImage(hit);
        _imgDragPointer = e.pointer;
        _imgResizing = false;
        _imgDragLast = e.localPosition;
        _imgDragStarted = false;
        _primary = e.pointer;
        return;
      }
      if (_selectedImageId != null) {
        _selectImage(null);
      } else {
        widget.onImageSelected(null);
      }
      if (widget.tool == ToolMode.pen) _deselectTapArmed = e.pointer;
    }
    // 橡皮：開會話，落筆點立即試刪（點按空白不留 checkpoint；可跨頁）
    if (widget.tool == ToolMode.strokeEraser ||
        widget.tool == ToolMode.pixelEraser) {
      _erasing = true;
      _erasePath = [stacked];
      _primary = e.pointer;
      // 落筆點立即試刪（點按即擦；點按空白不留 checkpoint；可跨頁）
      final page = _pageOfY(stacked.dy);
      if (widget.tool == ToolMode.strokeEraser) {
        widget.onStrokeEraseTick([_localOf(stacked, page)], page);
      } else {
        widget.onPixelEraseTick([_localOf(stacked, page)], page);
      }
      setState(() {});
      return;
    }
    final page = _pageOfY(stacked.dy);
    final pos = _clampLocal(_localOf(stacked, page), page);
    _tracker.reset();
    _tracker.emaWeight = widget.params.emaWeight;
    final live = LiveStroke(
        color: widget.color,
        size: widget.size,
        page: page,
        penType: widget.penType,
        alpha: widget.hlAlpha);
    live.positions.add(pos);
    live.pressures.add(1.0); // 起筆第一個點 pressure=1.0（落筆頓一下出粗點）
    live.times.add(e.timeStamp);
    _dwellAnchor = pos;
    _dwellAnchorTime = e.timeStamp;
    _armDwell();
    _primary = e.pointer;
    setState(() {
      _live = live;
      _liveOutline = [];
    });
  }

  void _onMove(PointerMoveEvent e) {
    // 雙指點按：兩指都在時中點漂移 >14px 就不算點按；三指以上直接取消
    if (_touchCount() > 2) {
      _twoTapDownTime = null;
      _twoTapDownMid = null;
    } else if (_twoTapDownTime != null && _touchCount() == 2) {
      final mid = _touchMid();
      if (mid != null &&
          _twoTapDownMid != null &&
          (mid - _twoTapDownMid!).distance > 14) {
        _twoTapMoved = true;
      }
    }
    // 右鍵平移中（屏幕位移直接加到 pan 上）
    if (_rightPanLast != null &&
        _active.containsKey(e.pointer) &&
        e.buttons & kSecondaryMouseButton != 0) {
      widget.onPanUpdate(e.localPosition - _rightPanLast!);
      _rightPanLast = e.localPosition;
      _active[e.pointer] = e.localPosition;
      return;
    }
    // 雙指：平移 + 捏合縮放（只看參與手勢的指針，手掌误放不攪局）
    if (_twoFinger) {
      final prev = _active[e.pointer];
      _track(e.pointer, e.localPosition, e.kind, e.timeStamp);
      final fingers = _active.entries
          .where((en) =>
              en.key != e.pointer &&
              ((_kinds[en.key] != null &&
                  _triggersGesture(_kinds[en.key]!))))
          .toList();
      if (prev != null && fingers.isNotEmpty) {
        final other = fingers.first.value;
        final oldDist = (prev - other).distance;
        final newDist = (e.localPosition - other).distance;
        final oldMid = (prev + other) / 2;
        final newMid = (e.localPosition + other) / 2;
        widget.onPanUpdate(newMid - oldMid);
        if (oldDist > 0 && newDist > 0) {
          widget.onZoomUpdate(newDist / oldDist, newMid);
        }
      }
      return;
    }
    if (_blockUntilLift) return;
    // 圖片拖動/縮放中（僅所屬指針；增量是內容 px，meta 取最新值累加不丟幀）
    if (_imgDragPointer != null &&
        e.pointer == _imgDragPointer &&
        _imgDragLast != null) {
      final d = (e.localPosition - _imgDragLast!) / widget.scale;
      _imgDragLast = e.localPosition;
      final meta = _selectedMeta();
      if (meta != null && (d.dx != 0 || d.dy != 0)) {
        // 首動才通知上層 checkpoint（純點選不留空 undo）
        if (!_imgDragStarted) {
          _imgDragStarted = true;
          widget.onImageDragStart();
        }
        if (_imgResizing) {
          // 右下拖：按對角線增量等比（右/下為正＝放大）
          final f = (1 + (d.dx + d.dy) / (meta.w + meta.h)).clamp(0.05, 8.0);
          final r = meta.scaled(f);
          widget.onImageChanged(meta.id, r.x, r.y, r.w, r.h);
        } else {
          widget.onImageChanged(
              meta.id, meta.x + d.dx, meta.y + d.dy, meta.w, meta.h);
        }
        if (mounted) setState(() {});
      }
      return;
    }
    if (!_active.containsKey(e.pointer)) return;
    _track(e.pointer, e.localPosition, e.kind, e.timeStamp);
    // 單指平移中（僅所屬指針）
    if (_singlePanLast != null) {
      if (e.pointer != _primary) return;
      widget.onPanUpdate(e.localPosition - _singlePanLast!);
      _singlePanLast = e.localPosition;
      return;
    }
    final stacked = _content(e.localPosition);
    if (widget.tool == ToolMode.lasso) {
      if (_primary != null && e.pointer != _primary) return;
      // 旋轉中：算繞中心的角度增量（堆疊座標系，平移不變）
      if (_rotating && _rotateCenter != null) {
        final c = _rotateCenter!;
        final now = _angleOf(stacked, c);
        var d = now - _rotateLastAng;
        while (d > math.pi) {
          d -= 2 * math.pi;
        }
        while (d < -math.pi) {
          d += 2 * math.pi;
        }
        _rotateLastAng = now;
        if (d.abs() > 0.002) {
          widget.onSelectionRotate(d, c);
          // 手柄跟著內容一起轉
          _handleAng = (_handleAng ?? math.pi / 2) + d;
        }
        return;
      }
      if (_movingSel) {
        if (_lastLocal != null) {
          widget.onSelectionMove(
              (e.localPosition - _lastLocal!) / widget.scale);
        }
        _lastLocal = e.localPosition;
        return;
      }
      if (_lassoPath.isEmpty ||
          (_lassoPath.last - stacked).distance > 2 / widget.scale) {
        setState(() => _lassoPath = [..._lassoPath, stacked]);
      }
      return;
    }
    if (!_acceptKind(e.kind)) return;
    // 橡皮拖動中：兩種都按段即刪即回調（按頁拆成連段，頁內座標）
    if (_erasing &&
        (_primary == null || e.pointer == _primary) &&
        (widget.tool == ToolMode.pixelEraser ||
            widget.tool == ToolMode.strokeEraser)) {
      if (_erasePath.isEmpty ||
          (_erasePath.last - stacked).distance > 2 / widget.scale) {
        final prev = _erasePath.isEmpty ? stacked : _erasePath.last;
        final grown = interpolateGap(prev, stacked, maxGap: 4.0);
        setState(() => _erasePath = [..._erasePath, ...grown]);
        if (grown.isNotEmpty) {
          // 跨頁拖抹按頁拆成連段，分別回調頁內座標
          var runPage = _pageOfY(grown.first.dy);
          var run = <Offset>[];
          void flush() {
            if (run.isNotEmpty) {
              final seg = [for (final p in run) _localOf(p, runPage)];
              if (widget.tool == ToolMode.strokeEraser) {
                widget.onStrokeEraseTick(seg, runPage);
              } else {
                widget.onPixelEraseTick(seg, runPage);
              }
              run = <Offset>[];
            }
          }

          for (final p in grown) {
            final pg = _pageOfY(p.dy);
            if (pg != runPage) {
              flush();
              runPage = pg;
            }
            run.add(p);
          }
          flush();
        }
      }
      return;
    }
    final live = _live;
    if (live == null) return;
    final pos = _clampLocal(_localOf(stacked, live.page), live.page);
    final last = live.positions.last;
    // 去重：近乎重合的點不收（防按住抖結坨），其餘全收保形狀——
    // 小字慢寫的相鄰點只有 1~3px，6px 一刀切會把彎拉成直線（「2」變「1」）。
    final gap = (pos - last).distance;
    if (gap < 1.5 / widget.scale) {
      return;
    }
    final interpolated = interpolateGap(last, pos);
    _tracker.emaWeight = widget.params.emaWeight;
    for (final p in interpolated) {
      final speed = _tracker.add(p, e.timeStamp);
      final pressure = ink.speedToPressure(speed, widget.params.maxSpeed);
      live.positions.add(p);
      live.pressures.add(pressure);
      live.times.add(e.timeStamp);
    }
    // 停頓錨點：相對錨點位移超限才算真移動，重計停頓；
    // 筆靜止噪聲/按住手抖永不推動錨點，停頓計時照走、收筆 dwell 照算。
    // 動起來自動切回原軌跡（_armDwell 順手清預覽）。
    if ((pos - _dwellAnchor).distance >= 6 / widget.scale) {
      _dwellAnchor = pos;
      _dwellAnchorTime = e.timeStamp;
      _armDwell();
    }
    // 進行中的筆畫：重算輪廓並重繪。
    // 長筆優化：perfect_freehand 是整筆重算（O(n²) 級），點多了每事件都算會卡；
    // 數據照常全收，輪廓最多 60fps 刷新，收筆時快照/縮圖用全量數據。
    final heavy = live.positions.length > 80;
    final due = (e.timeStamp - _lastOutlineAt).inMicroseconds >= 16000;
    if (widget.penType != PenType.brush || !heavy || due) {
      if (heavy) _lastOutlineAt = e.timeStamp;
      setState(() {
        if (widget.penType != PenType.brush || live.positions.length < 2) {
          _liveOutline = [];
        } else {
          _liveOutline = strokeOutline(live.positions, live.pressures,
              params: widget.params);
        }
      });
    }
  }

  // 雙指點按（undo/redo）：原始觸屏計數，不受防誤觸/工具限制
  Duration? _twoTapDownTime;
  Offset? _twoTapDownMid;
  bool _twoTapMoved = false;
  final List<Duration> _twoTapTimes = [];
  Timer? _twoTapTimer;
  // 觸控板捏合沒有抬起事件，停手計時算縮放結束
  Timer? _zoomEndTimer;

  int _touchCount() {
    var n = 0;
    for (final id in _active.keys) {
      if (_kinds[id] == PointerDeviceKind.touch) n++;
    }
    return n;
  }

  Offset? _touchMid() {
    var x = 0.0, y = 0.0, n = 0;
    for (final entry in _active.entries) {
      if (_kinds[entry.key] == PointerDeviceKind.touch) {
        x += entry.value.dx;
        y += entry.value.dy;
        n++;
      }
    }
    if (n == 0) return null;
    return Offset(x / n, y / n);
  }

  // 第二下已提前觸發 undo（窗口未關，再來第三下就進補償分支）
  bool _twoTapFiredUndo = false;

  void _registerTwoTap(Duration now) {
    _twoTapTimes.removeWhere((t) => (now - t).inMicroseconds > 500 * 1000);
    _twoTapTimes.add(now);
    _twoTapTimer?.cancel();
    if (_twoTapTimes.length == 2 && !_twoTapFiredUndo) {
      // 第二下抬起立刻 undo，不等 500ms；窗口照開 500ms 等第三下
      widget.onTwoFingerDoubleTap();
      _twoTapFiredUndo = true;
      _twoTapTimer = Timer(const Duration(milliseconds: 500), () {
        _twoTapTimes.clear();
        _twoTapFiredUndo = false;
      });
      return;
    }
    if (_twoTapTimes.length >= 3 && _twoTapFiredUndo) {
      // 第三下：淨效果應為 1 redo。前面已提前 undo 一次，
      // 先 redo 撤銷它，再 redo 一次（三擊本義），共兩次
      _twoTapTimes.clear();
      _twoTapFiredUndo = false;
      widget.onTwoFingerTripleTap();
      widget.onTwoFingerTripleTap();
      return;
    }
    // 首下或窗口外的新序列：只開窗等下一點
    _twoTapTimer = Timer(const Duration(milliseconds: 500), () {
      _twoTapTimes.clear();
      _twoTapFiredUndo = false;
    });
  }

  Offset? _midpoint() {
    final fingers = _active.entries
        .where((en) =>
            _kinds[en.key] != null && _triggersGesture(_kinds[en.key]!))
        .toList();
    if (fingers.length < 2) return null;
    var x = 0.0, y = 0.0;
    for (final p in fingers) {
      x += p.value.dx;
      y += p.value.dy;
    }
    return Offset(x / fingers.length, y / fingers.length);
  }

  int _gestureActiveCount() {
    var n = 0;
    for (final id in _active.keys) {
      final k = _kinds[id];
      if (k != null && _triggersGesture(k)) n++;
    }
    return n;
  }

  void _onUp(PointerUpEvent e) {
    final known = _active.containsKey(e.pointer);
    // 雙指釋放：夠快夠直的縱向快掃視為翻頁
    if (_twoFinger && _gestureActiveCount() <= 2) {
      final mid = _midpoint();
      final t0 = _twoStartTime;
      final m0 = _twoStartMid;
      if (mid != null && m0 != null && t0 != null) {
        final dt = (e.timeStamp - t0).inMicroseconds / 1e6;
        final dir = flickDir(mid - m0, dt);
        if (dir != 0) widget.onPageFlick(dir);
      }
    }
    _untrack(e.pointer);
    // 雙指點按結算：兩指都抬起、沒漂移、夠快 → 記一次；還剩手指就繼續等
    if (_twoTapDownTime != null && _touchCount() == 0) {
      if (!_twoTapMoved &&
          (e.timeStamp - _twoTapDownTime!).inMicroseconds < 400 * 1000) {
        _registerTwoTap(e.timeStamp);
      }
      _twoTapDownTime = null;
      _twoTapDownMid = null;
    }
    if (!known) return; // 沒見過的指針：只清記錄，不碰進行中的筆
    // 手掌抬起不碰筆的停頓計時
    if (!_isPalmIntrusion(e)) _cancelDwell();
    if (_rightPanLast != null && _active.isEmpty) _rightPanLast = null;
    if (_twoFinger) {
      if (_active.length < 2) {
        _twoFinger = false;
        _twoStartMid = null;
        _twoStartTime = null;
        // 剩餘手指抬起前不再書寫，避免甩出 stray 筆畫
        if (_active.isNotEmpty) _blockUntilLift = true;
        widget.onZoomEnd?.call();
      }
      return;
    }
    if (_active.isEmpty) _blockUntilLift = false;
    // 圖片拖動結束（僅所屬指針）：選中保留；沒動過只清狀態不結算
    if (_imgDragPointer != null && e.pointer == _imgDragPointer) {
      final wasStarted = _imgDragStarted;
      _imgDragPointer = null;
      _imgResizing = false;
      _imgDragLast = null;
      _imgDragStarted = false;
      if (_primary == e.pointer) _primary = null;
      if (wasStarted) widget.onImageDragEnd();
      return;
    }
    if (_singlePanLast != null) {
      // 單指平移抬起：無後續動作（位移已在 move 裡結清）
      _singlePanLast = null;
      if (_primary == e.pointer) _primary = null;
      return;
    }
    // 橡皮會話結束：兩種早已逐段刪光，這裡只清游標結算（僅所屬指針）
    if (_erasing) {
      if (e.pointer != _primary) return;
      _erasing = false;
      _primary = null;
      final path = _erasePath;
      setState(() => _erasePath = []);
      if (widget.tool == ToolMode.pixelEraser) {
        // 收尾补一段：up 位置超出末段时对齐（落筆頁內）
        if (path.isNotEmpty) {
          final upPos = _content(e.localPosition);
          if ((upPos - path.last).distance > 1) {
            final page = _pageOfY(upPos.dy);
            widget.onPixelEraseTick([_localOf(upPos, page)], page);
          }
        }
        widget.onPixelEraseEnd();
      } else if (widget.tool == ToolMode.strokeEraser) {
        widget.onStrokeEraseEnd();
      }
      return;
    }
    if (widget.tool == ToolMode.lasso) {
      if (_primary != null && e.pointer != _primary) return;
      _primary = null;
      final wasMoving = _movingSel;
      _movingSel = false;
      final wasRotating = _rotating;
      _rotating = false;
      _rotateCenter = null;
      if (wasMoving) {
        // 收尾补一次：中途丢帧的位移以 up 位置为准对齐
        if (_lastLocal != null &&
            (e.localPosition - _lastLocal!).distance > 0.5) {
          widget.onSelectionMove(
              (e.localPosition - _lastLocal!) / widget.scale);
        }
        _lastLocal = null;
        // 拖完才結算出紙裁剪（中途路過不算數）
        widget.onSelectionEnd();
      } else if (!wasRotating) {
        final upPos = _content(e.localPosition);
        if (_lassoPath.isEmpty ||
            (_lassoPath.last - upPos).distance > 1) {
          _lassoPath = [..._lassoPath, upPos];
        }
        if (_lassoPath.length >= 3) {
          // 圈取歸屬點數最多那一頁（跨頁圈按多數頁算，形心在縫裡也不怕）
          final votes = <int, int>{};
          for (final p in _lassoPath) {
            final pg = _pageOfY(p.dy);
            votes[pg] = (votes[pg] ?? 0) + 1;
          }
          var page = _pageOfY(_lassoPath.first.dy);
          var best = -1;
          votes.forEach((pg, n) {
            if (n > best) {
              best = n;
              page = pg;
            }
          });
          widget.onLassoCompleted(
              [..._lassoPath, _lassoPath.first], page);
        }
      }
      setState(() => _lassoPath = []);
      return;
    }
    if (!_acceptKind(e.kind)) {
      // 被拒的指針（手掌）抬起：只清自己的，不碰別人的書寫會話
      if (_primary == null || e.pointer == _primary) {
        _live = null;
        _primary = null;
      }
      return;
    }
    if (_primary != null && e.pointer != _primary) return;
    _primary = null;
    final live = _live;
    _live = null;
    if (live == null) {
      return;
    }
    // 取消點：有圖選中時點圖外，沒畫出東西就不提交（只取消選中）；
    // 真畫了就正常落筆。
    if (_deselectTapArmed != null && e.pointer == _deselectTapArmed) {
      _deselectTapArmed = null;
      if (live.positions.length <= 1) {
        _cancelDwell();
        setState(() => _liveOutline = []);
        return;
      }
    }
    // 真實停頓 = 抬起時刻 - 末個真移動時刻（噪聲/抖動不刷新錨點；
    // 收尾補點之前算，否則恆為 0）
    final dwellMs =
        (e.timeStamp - _dwellAnchorTime).inMicroseconds ~/ 1000;
    if (live.positions.length == 1) {
      // 單點：保留為點筆（渲染為圓）
    } else {
      // 收尾补一点：中途丢帧导致笔画偏短时对齐到 up 位置（落筆頁內）
      final end = _clampLocal(_localOf(_content(e.localPosition), live.page),
          live.page);
      if ((end - live.positions.last).distance > 1) {
        live.positions.add(end);
        live.pressures.add(live.pressures.last);
        live.times.add(e.timeStamp);
      }
    }
    setState(() => _liveOutline = []);
    widget.onStrokeCompleted(live.toStroke(), dwellMs);
  }

  void _onCancel(PointerCancelEvent e) {
    _untrack(e.pointer);
    _cancelDwell();
    if (_deselectTapArmed != null && e.pointer == _deselectTapArmed) {
      _deselectTapArmed = null;
    }
    if (_primary != null && e.pointer != _primary) return;
    _primary = null;
    final wasTwoFinger = _twoFinger;
    _twoFinger = false;
    if (wasTwoFinger) widget.onZoomEnd?.call();
    _rightPanLast = null;
    _singlePanLast = null;
    _rotating = false;
    _rotateCenter = null;
    final wasErasing = _erasing;
    final wasPixel = widget.tool == ToolMode.pixelEraser;
    _erasing = false;
    _erasePath = [];
    if (wasErasing) {
      // 逐段已刪光，只結算（像素/按筆畫各走各的 End）
      if (wasPixel) {
        widget.onPixelEraseEnd();
      } else {
        widget.onStrokeEraseEnd();
      }
    }
    // 圖片拖動被取消：停跟手，動過才結算（選中保留）
    if (_imgDragPointer != null && e.pointer == _imgDragPointer) {
      final wasStarted = _imgDragStarted;
      _imgDragPointer = null;
      _imgResizing = false;
      _imgDragLast = null;
      _imgDragStarted = false;
      if (wasStarted) widget.onImageDragEnd();
    }
    if (_active.isEmpty) _blockUntilLift = false;
    _live = null;
    _lassoPath = [];
    _movingSel = false;
    setState(() => _liveOutline = []);
  }

  void _onSignal(PointerSignalEvent e) {
    // 滾輪平移畫布（A4 紙比螢幕長時滾動查看）
    if (e is PointerScrollEvent) {
      widget.onPanUpdate(Offset(-e.scrollDelta.dx, -e.scrollDelta.dy));
      return;
    }
    // 觸控板捏合縮放（以游標為中心）；停手 400ms 算一次縮放結束
    if (e is PointerScaleEvent) {
      final box = context.findRenderObject() as RenderBox?;
      if (box == null) return;
      widget.onZoomUpdate(e.scale, box.globalToLocal(e.position));
      _zoomEndTimer?.cancel();
      _zoomEndTimer = Timer(const Duration(milliseconds: 400), () {
        _zoomEndTimer = null;
        widget.onZoomEnd?.call();
      });
    }
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    _twoTapTimer?.cancel();
    _zoomEndTimer?.cancel();
    _completedPicture?.dispose();
    _bgPicture?.dispose();
    for (final v in _bgImgs.values) {
      v.dispose();
    }
    for (final v in _retiredBgImgs.values) {
      v.dispose();
    }
    for (final v in _noteImgs.values) {
      v.dispose();
    }
    for (final v in _retiredNoteImgs.values) {
      v.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      onPointerSignal: _onSignal,
      // ClipRect：紙/筆跡不許塗到隔壁 pane（rail/列表）上去
      child: ClipRect(
        child: CustomPaint(
          painter: _InkPainter(
            bg: _bgPicture,
            completed: _completedPicture,
            liveOutline: _liveOutline,
            livePositions: _live?.positions,
            livePage: _live?.page ?? 0,
            snapPreview: _snapPreview,
            liveColor: _live?.color,
            livePenType: _live?.penType ?? widget.penType,
            liveSize: _live?.size ?? widget.size,
            liveAlpha: _live?.alpha ?? widget.hlAlpha,
            hlWidth: widget.hlWidth,
            eraserCursor:
                _erasePath.isNotEmpty ? _erasePath.last : null,
            eraserRadius: widget.tool == ToolMode.pixelEraser
                ? widget.pixelRadius
                : widget.strokeThreshold,
            params: widget.params,
            pageRects: widget.pageRects,
            panOffset: widget.panOffset,
            scale: widget.scale,
            lassoPath: _lassoPath,
            selectionRect: widget.selectionRect,
            rotateHandle: _rotateHandle(),
            rotateCenter: _stackedBounds()?.center,
            images: widget.images,
            selectedImageId: _selectedImageId,
            selectedImageIds: widget.selectedImageIds,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _InkPainter extends CustomPainter {
  // 底圖層（先畫）與筆跡層（後畫）：分開烘焙、分開畫
  final ui.Picture? bg;
  final ui.Picture? completed;
  final List<Offset> liveOutline;
  final List<Offset>? livePositions;
  /// 進行中筆畫所在頁（頁內座標 → 堆疊需平移）。
  final int livePage;
  final List<Stroke>? snapPreview;
  final String? liveColor;
  final PenType livePenType;
  final double liveSize;
  final double liveAlpha;
  final double hlWidth;
  final Offset? eraserCursor;
  final double eraserRadius;
  final ink.StrokeParams params;
  final List<Rect> pageRects;
  final Offset panOffset;
  final double scale;
  final List<Offset> lassoPath;
  final Rect? selectionRect;
  /// 旋轉手柄（堆疊座標，轉動中會繞中心公轉）及其中心。
  final Offset? rotateHandle;
  final Offset? rotateCenter;
  /// 貼圖 meta（選中框定位用；圖本身已烘進 completed）。
  final List<NoteImage> images;
  /// 已選中圖片 id（單選拖動用，虛線框＋右下縮放手柄）與圈選集合（只畫框）。
  final String? selectedImageId;
  final Set<String> selectedImageIds;

  _InkPainter({
    this.bg,
    required this.completed,
    required this.liveOutline,
    required this.livePositions,
    required this.livePage,
    required this.snapPreview,
    required this.liveColor,
    required this.livePenType,
    required this.liveSize,
    required this.liveAlpha,
    required this.hlWidth,
    required this.eraserCursor,
    required this.eraserRadius,
    required this.params,
    required this.pageRects,
    required this.panOffset,
    required this.scale,
    required this.lassoPath,
    required this.selectionRect,
    required this.rotateHandle,
    required this.rotateCenter,
    required this.images,
    required this.selectedImageId,
    required this.selectedImageIds,
  });

  /// 頁內座標平移到堆疊座標。
  Offset _shift(Offset p, int page) {
    if (pageRects.isEmpty || page < 0 || page >= pageRects.length) return p;
    return p + Offset(0, pageRects[page].top - 24);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(panOffset.dx, panOffset.dy);
    canvas.scale(scale);
    // 頁面紙張底（連續多頁垂直堆疊；無限畫布不畫）
    for (final page in pageRects) {
      canvas.drawShadow(
        Path()..addRect(page),
        const Color(0x55000000),
        8,
        true,
      );
      canvas.drawRect(page, Paint()..color = const Color(0xFFFFFFFF));
      canvas.drawRect(
        page,
        Paint()
          ..color = const Color(0xFFBDBDBD)
          ..style = PaintingStyle.stroke,
      );
    }
    // 已完成：先底圖層，後筆跡層＋貼圖層（分開烘焙，不得每幀重繪全部；
    // 貼圖已按圖層烘進 completed，這裡只畫選中框）
    final bgPic = bg;
    if (bgPic != null) canvas.drawPicture(bgPic);
    final pic = completed;
    if (pic != null) canvas.drawPicture(pic);
    // 停頓預覽：藏原軌跡，直接畫預測形狀（頁內 → 堆疊）
    final preview = snapPreview;
    if (preview != null) {
      canvas.save();
      final o = _shift(Offset.zero, livePage);
      canvas.translate(o.dx, o.dy);
      for (final s in preview) {
        paintStroke(canvas, s, hlWidth: hlWidth, params: params);
      }
      canvas.restore();
    } else {
      _paintLive(canvas);
    }
    final cursor = eraserCursor;
    if (cursor != null) {
      canvas.drawCircle(
        cursor,
        eraserRadius,
        Paint()
          ..color = const Color(0xFF757575)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    _paintDashedLoop(canvas, lassoPath, const Color(0xFF757575));
    // 選中物件的虛線框：包圍盒矩形（堆疊座標，直接畫）
    final box = selectionRect;
    if (box != null) {
      _paintDashedLoop(canvas, [
        box.topLeft,
        box.topRight,
        box.bottomRight,
        box.bottomLeft,
        box.topLeft,
      ], const Color(0xFF3B5BFD));
      // 旋轉手柄：圓鈕 + 朝中心方向的短柄（轉動中繞中心公轉）
      final handle = rotateHandle;
      final center = rotateCenter;
      if (handle != null && center != null) {
        final dir = center - handle;
        final len = dir.distance;
        if (len > 1e-6) {
          final tail = handle + dir / len * (24 / scale);
          canvas.drawLine(
            handle,
            tail,
            Paint()
              ..color = const Color(0xFF3B5BFD)
              ..strokeWidth = 1.5,
          );
        }
        canvas.drawCircle(
          handle,
          14 / scale,
          Paint()..color = const Color(0xFF3B5BFD),
        );
        // 圓鈕內的旋轉箭頭（兩段弧線示意）
        canvas.drawArc(
          Rect.fromCircle(center: handle, radius: 7 / scale),
          -0.4,
          3.6,
          false,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / scale
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    // 選中圖片的虛線框（單選另帶右下縮放手柄；堆疊座標，直接畫）
    for (final m in images) {
      final isSel =
          m.id == selectedImageId || selectedImageIds.contains(m.id);
      if (!isSel) continue;
      final o = _shift(Offset.zero, m.page);
      final box = Rect.fromLTWH(o.dx + m.x, o.dy + m.y, m.w, m.h);
      _paintDashedLoop(canvas, [
        box.topLeft,
        box.topRight,
        box.bottomRight,
        box.bottomLeft,
        box.topLeft,
      ], const Color(0xFF3B5BFD));
      if (m.id != selectedImageId) continue;
      final handle = box.bottomRight;
      canvas.drawCircle(
        handle,
        12 / scale,
        Paint()..color = const Color(0xFF3B5BFD),
      );
      canvas.drawCircle(
        handle,
        12 / scale,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale,
      );
    }
    canvas.restore();
  }

  void _paintLive(Canvas canvas) {
    // 進行中筆畫為頁內座標 → 先平移到堆疊
    final o = _shift(Offset.zero, livePage);
    canvas.save();
    canvas.translate(o.dx, o.dy);
    _paintLiveShifted(canvas);
    canvas.restore();
  }

  void _paintLiveShifted(Canvas canvas) {
    final color = _parse(liveColor ?? '#000000');
    if (livePenType == PenType.dashed) {
      final raw = livePositions;
      if (raw != null && raw.length >= 2) {
        var pts = raw;
        final len = pathLength(pts);
        if (len > 0) pts = resamplePoints(pts, (len / 2).ceil().clamp(2, 4000));
        canvas.drawPath(
          dashPath(pts, liveSize * 2.5, liveSize * 1.5),
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = liveSize
            ..strokeCap = StrokeCap.round,
        );
      }
      return;
    }
    if (livePenType == PenType.highlighter) {
      final pts = livePositions;
      if (pts != null && pts.isNotEmpty) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (var i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: liveAlpha.clamp(0.05, 1.0))
            ..style = PaintingStyle.stroke
            ..strokeWidth = liveSize * hlWidth
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      return;
    }
    if (liveOutline.length >= 3) {
      final path = Path()..moveTo(liveOutline.first.dx, liveOutline.first.dy);
      for (var i = 1; i < liveOutline.length; i++) {
        path.lineTo(liveOutline[i].dx, liveOutline[i].dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
    } else if (livePositions != null && livePositions!.isNotEmpty) {
      final pos = livePositions!.last;
      canvas.drawCircle(
        pos,
        params.size * 0.5,
        Paint()..color = color,
      );
    }
  }

  void _paintDashedLoop(Canvas canvas, List<Offset> loop, Color color) {
    if (loop.length < 2) return;
    canvas.drawPath(
      dashPath(loop, 8, 6),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
  }

  Color _parse(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.parse(h, radix: 16));
  }

  @override
  bool shouldRepaint(_InkPainter old) => true;
}
