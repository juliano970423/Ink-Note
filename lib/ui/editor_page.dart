import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../export/export_saver.dart';
import '../export/note_pdf.dart';
import '../export/vector_pdf.dart';
import '../import/pdf_import.dart';
import '../import/pdf_vector.dart';
import 'package:pdf_document/pdf_document.dart';
import '../ink/stroke_renderer.dart';
import '../ink/velocity_tracker.dart';
import '../models/note.dart';
import '../settings/app_settings.dart';
import '../storage/note_store.dart';
import 'eraser_icons.dart';
import 'ink_canvas.dart';

/// 視圖：正常 / 全屏（留工具欄+頁碼，收側欄） / 沉浸（什麼都不顯示）。
enum ViewMode { normal, fullscreen, zen }

/// 撤銷快照：筆跡 + 圖層名 + 隱藏 + 使用中圖層（圖層結構變動一起撤銷）。
class _HistoryEntry {
  final List<Stroke> strokes;
  final List<String> layerNames;
  final List<int> hidden;
  final int active;

  _HistoryEntry({
    required this.strokes,
    required this.layerNames,
    required this.hidden,
    required this.active,
  });
}

/// 編輯頁：全屏畫布 + 頂部最小懸浮半透明工具欄（不吃畫布空間）。
/// 保存策略：筆畫結束後 debounce 2 秒自動保存，禁止每筆一存。
class EditorPage extends StatefulWidget {
  final NoteStore repo;
  final AppSettings settings;
  final Note note;
  final VoidCallback? onSaved;
  /// 視圖變化回調（寬屏下 HomePage 聯動收起 rail+列表）。
  final ValueChanged<ViewMode>? onViewChanged;

  const EditorPage({
    super.key,
    required this.repo,
    required this.settings,
    required this.note,
    this.onSaved,
    this.onViewChanged,
  });

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late Note _note;
  late StrokeParams _params;
  late String _color;
  late double _brushSize;
  late PenType _penType;
  late double _hlAlpha;
  late double _hlWidth;
  late double _pixelRadius;
  late double _strokeThreshold;
  ToolMode _tool = ToolMode.pen;
  ToolMode _lastEraser = ToolMode.strokeEraser;
  ViewMode _view = ViewMode.normal;
  ViewMode _beforeZen = ViewMode.normal;
  late bool _readOnly;
  int _pageIndex = 0;
  Offset _panOffset = Offset.zero;
  double _scale = 1.0;
  Set<Stroke> _selected = {};
  int _selectionPage = 0;

  /// 選中物件的虛線框（堆疊座標）：包圍盒外擴，零高度選區也看得見。
  Rect? get _selectionRect {
    final b = _selectionBounds;
    if (b == null) return null;
    if (_pageRects.isEmpty) return b.inflate(10 / _scale);
    if (_selectionPage < 0 || _selectionPage >= _pageRects.length) {
      return b.inflate(10 / _scale);
    }
    return b
        .shift(Offset(0, _pageRects[_selectionPage].top - 24))
        .inflate(10 / _scale);
  }
  Timer? _saveTimer;
  bool _saving = false;
  bool _exporting = false;
  /// PDF 底圖解碼快取（頁 → 圖），與筆畫畫進同一張 Picture（底圖在最下）。
  Map<int, ui.Image> _bgImages = {};
  /// 已解碼底圖寬度（頁 → px）：縮放後不夠銳就從原 PDF 按需重渲染。
  Map<int, int> _bgWidths = {};
  /// 原 PDF 字節（向量源頭 + 高清底圖來源；普通筆記為 null，懶載入）。
  Uint8List? _origPdfBytes;
  bool _bgUpgrading = false;
  /// 後台填充進行中（懶載入導入的剩餘頁；與升級互斥共用一道門）。
  bool _fillingBg = false;
  Note? _bgNote;
  final GlobalKey<InkCanvasState> _canvasKey = GlobalKey();
  late final List<MenuController> _slotMenus;
  final MenuController _eraserMenu = MenuController();
  final MenuController _moreMenu = MenuController();
  late TextEditingController _titleCtrl;
  Size _viewportSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _slotMenus = List.generate(
        widget.settings.quickPens.length, (_) => MenuController());
    _note = widget.note;
    _color = widget.settings.lastColor;
    _brushSize = widget.settings.lastSize;
    _penType = PenTypeLabel.parse(widget.settings.lastPenType);
    _hlAlpha = widget.settings.lastHlAlpha;
    _hlWidth = widget.settings.lastHlWidth;
    _pixelRadius = widget.settings.pixelEraserSize;
    _strokeThreshold = widget.settings.strokeEraserSize;
    _readOnly = widget.settings.readOnly;
    _activeLayer =
        _note.layerNames.isEmpty ? 0 : _note.layerNames.length - 1;
    _params = StrokeParams(
      maxSpeed: widget.settings.deviceProfile.maxSpeed,
      emaWeight: widget.settings.deviceProfile.emaWeight,
      thinning: widget.settings.deviceProfile.thinning,
      streamline: widget.settings.deviceProfile.streamline,
      size: _brushSize,
    );
    _titleCtrl = TextEditingController(text: _note.title);
    _refreshBgImages();
    if (_hasPdfPages) {
      // 懒加载导入：首屏秒开，其余页后台填像素
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _fillMissingBg());
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _titleCtrl.dispose();
    for (final img in _bgImages.values) {
      img.dispose();
    }
    super.dispose();
  }

  /// 底圖解碼跟上當前筆記（打開/回滾後調用），好了就推給畫布重建。
  Future<void> _refreshBgImages() async {
    if (!identical(_bgNote, _note)) {
      for (final img in _bgImages.values) {
        img.dispose();
      }
      _bgImages = {};
      _bgWidths = {};
      _bgNote = _note;
    }
    for (var i = 0; i < _note.backgrounds.length; i++) {
      if (_bgImages.containsKey(i)) continue;
      try {
        final bytes = await widget.repo.loadBackground(_note.id, _bgKey(i));
        if (bytes == null || !mounted) continue;
        final img = await decodePng(bytes);
        if (img != null && mounted) {
          _bgImages[i] = img;
          _bgWidths[i] = img.width;
        }
      } catch (_) {}
    }
    _canvasKey.currentState?.setBgImages(Map<int, ui.Image>.from(_bgImages));
  }

  /// 該頁底圖鍵（舊文件無 key 兜底 `p{i}`，對應首次讀取自動改名的舊檔）。
  String _bgKey(int i) {
    final k = _note.backgrounds[i].key;
    return k.isEmpty ? 'p$i' : k;
  }

  /// 頁面結構變化（排序/增刪）後：全部按鍵重載（位置變了，按鍵取是對的）。
  Future<void> _reloadBgImages() async {
    for (final img in _bgImages.values) {
      img.dispose();
    }
    _bgImages = {};
    _bgWidths = {};
    _bgNote = _note;
    await _refreshBgImages();
  }

  /// 可見內容縱向範圍（堆疊座標；上下各多留一頁，免得一滾就糊）。
  /// 視口未知時返回無窮（= 全部可見，調用方自行決定要不要全量）。
  (double, double) _viewTopBottom() {
    final vs = _viewportSize;
    if (vs.isEmpty) return (double.negativeInfinity, double.infinity);
    final top = (0 - _panOffset.dy) / _scale - _bgWidth;
    final bottom = (vs.height - _panOffset.dy) / _scale + _bgWidth;
    return (top, bottom);
  }

  /// 填充顺序：可見頁優先，其餘按序（懶載入感知，用戶先看到當下頁）。
  List<int> _fillOrder() {
    final n = _note.backgrounds.length;
    final (top, bottom) = _viewTopBottom();
    final rects = _pageRects;
    final inView = <int>[];
    final rest = <int>[];
    for (var i = 0; i < n; i++) {
      var vis = true;
      if (i < rects.length) {
        final r = rects[i];
        vis = !(r.bottom < top || r.top > bottom);
      }
      (vis ? inView : rest).add(i);
    }
    return [...inView, ...rest];
  }

  /// 後台填充缺失的底圖像素（懶載入導入的剩餘頁；2400 基線，可見優先）。
  /// 内存已有（升级的高清版）不降级；文件已有读文件；都没有才渲染。
  /// 存盘持久化（下次打开直接读文件）。测试环境无原 PDF 自动早退。
  Future<void> _fillMissingBg() async {
    if (_fillingBg || !_hasPdfPages) return;
    _fillingBg = true;
    try {
      var orig = _origPdfBytes;
      if (orig == null) {
        try {
          orig = await widget.repo.loadOriginalPdf(_note.id);
        } catch (_) {
          return;
        }
        if (!mounted) return;
        _origPdfBytes = orig;
      }
      if (orig == null) return;
      final note = _note;
      PdfDocument? doc;
      try {
        for (final i in _fillOrder()) {
          if (!mounted || !identical(_note, note)) return;
          if (i >= _note.backgrounds.length) break;
          if (_bgImages.containsKey(i)) continue;
          // 文件已有（别处填的/升级存的）读文件
          Uint8List? png;
          try {
            png = await widget.repo.loadBackground(_note.id, _bgKey(i));
          } catch (_) {}
          if (png == null) {
            final src = _bgSrc(i);
            if (src == null) continue;
            doc ??= PdfDocument.open(orig);
            if (src < 0 || src >= doc.pageCount) continue;
            final r = await renderPdfPageVector(doc, src, widthPx: 2400);
            if (!mounted || !identical(_note, note)) return;
            if (r == null) continue;
            png = r.png;
            try {
              await widget.repo.saveBackground(_note.id, _bgKey(i), png);
            } catch (_) {}
          }
          if (!mounted || !identical(_note, note)) return;
          try {
            final img = await decodePng(png);
            if (!mounted || !identical(_note, note)) {
              img?.dispose();
              return;
            }
            if (img == null) continue;
            setState(() {
              _bgImages[i]?.dispose();
              _bgImages[i] = img;
              _bgWidths[i] = img.width;
            });
            _canvasKey.currentState
                ?.setBgImages(Map<int, ui.Image>.from(_bgImages));
            _canvasKey.currentState?.invalidateCache();
          } catch (_) {}
          // 让帧：别把 UI 线程一口气占满
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      } finally {
        // PdfDocument 纯 Dart，GC 回收即可
      }
    } finally {
      _fillingBg = false;
    }
  }

  /// 該顯示頁對應的原 PDF 頁碼（空白頁返回 null，不渲染）。
  int? _bgSrc(int i) {
    final bg = _note.backgrounds[i];
    if (bg.src != null) return bg.src;
    final key = bg.key;
    if (key.isEmpty) return i;
    final m = RegExp(r'^p(\d+)$').firstMatch(key);
    if (m != null) return int.parse(m[1]!);
    return null;
  }

  /// 縮放結束後：可見頁解碼寬度不夠銳，從原 PDF 按需重渲染更高清的圖。
  /// 舊圖留著擋畫面（先畫舊的），新圖好了才換；只升不降；缺圖也順手補上。
  Future<void> _maybeUpgradeBg() async {
    if (_bgUpgrading || !_hasPdfPages) return;
    var orig = _origPdfBytes;
    if (orig == null) {
      try {
        orig = await widget.repo.loadOriginalPdf(_note.id);
      } catch (_) {
        return;
      }
      if (!mounted) return;
      _origPdfBytes = orig;
    }
    if (orig == null) return;
    final vs = _viewportSize;
    if (vs.isEmpty) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final rects = _pageRects;
    final (top, bottom) = _viewTopBottom();
    _bgUpgrading = true;
    try {
      for (var i = 0; i < _note.backgrounds.length; i++) {
        if (!mounted) return;
        if (i >= rects.length || i >= _note.backgrounds.length) break;
        final r = rects[i];
        if (r.bottom < top || r.top > bottom) continue;
        final target = bgUpgradeWidth(
            scale: _scale, dpr: dpr, decoded: _bgWidths[i] ?? 0);
        if (target == null) continue;
        final src = _bgSrc(i);
        if (src == null) continue;
        final rendered =
            await renderPdfPageAtWidth(orig, src, renderWidth: target);
        if (!mounted || rendered == null) continue;
        final img = await decodePng(rendered.png);
        if (!mounted) {
          img?.dispose();
          return;
        }
        if (img == null) continue;
        setState(() {
          _bgImages[i]?.dispose();
          _bgImages[i] = img;
          _bgWidths[i] = img.width;
        });
        _canvasKey.currentState
            ?.setBgImages(Map<int, ui.Image>.from(_bgImages));
        _canvasKey.currentState?.invalidateCache();
      }
    } finally {
      _bgUpgrading = false;
    }
  }

  @override
  void didUpdateWidget(EditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 手感參數住在設置頁（deviceProfile）：返回編輯器時同步，有變化就重建快取。
    final d = widget.settings.deviceProfile;
    if (_params.maxSpeed != d.maxSpeed ||
        _params.emaWeight != d.emaWeight ||
        _params.thinning != d.thinning ||
        _params.streamline != d.streamline) {
      _params = StrokeParams(
        maxSpeed: d.maxSpeed,
        emaWeight: d.emaWeight,
        thinning: d.thinning,
        streamline: d.streamline,
        size: _brushSize,
      );
      _canvasKey.currentState?.invalidateCache();
    }
  }

  void _scheduleAutosave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _doSave);
  }

  Future<void> _doSave() async {
    if (_saving) {
      // 上一輪還在寫：別丟，晚點再存一次（否則極端時序下丟保存）
      _scheduleAutosave();
      return;
    }
    _saving = true;
    try {
      _note.title =
          _titleCtrl.text.trim().isEmpty ? 'untitled' : _titleCtrl.text.trim();
      await widget.repo.save(_note);
      // 保存時渲染當前頁縮圖 PNG 存同目錄（底圖筆記帶上底圖）
      try {
        ui.Image? bg;
        Rect? bgRect;
        if (_note.backgrounds.isNotEmpty) {
          bg = _bgImages[_pageIndex];
          final meta = _pageIndex < _note.backgrounds.length
              ? _note.backgrounds[_pageIndex]
              : _note.backgrounds.last;
          bgRect = Rect.fromLTWH(
              24, 24, _bgWidth, _bgWidth * meta.h / meta.w);
        }
        final png = await renderThumbnail(
            _pageStrokes
                .where((s) => !_note.hiddenLayers.contains(s.layer))
                .toList(),
            hlWidth: _hlWidth,
            params: _params,
            bgImage: bg,
            bgRect: bgRect);
        if (png != null) {
          await widget.repo.saveThumbnail(_note.id, png);
        }
      } catch (_) {}
      widget.onSaved?.call();
      if (mounted) setState(() {});
    } finally {
      _saving = false;
    }
  }

  /// 當前頁筆畫（與 _note.strokes 同實例）。
  List<Stroke> get _pageStrokes =>
      _note.strokes.where((s) => s.page == _pageIndex).toList();

  /// 隱式總頁數：只看筆跡 + 顯式開出來的空頁，跟焦點頁無關
  /// （平移縮放改焦點時頁數不變，視角不跳）。
  int _blankExtra = 0;

  int get _pageCount {
    var top = -1;
    for (final s in _note.strokes) {
      if (s.page > top) top = s.page;
    }
    // 筆跡全空也有 1 頁（0 頁會讓紙框上下顛倒，clamp 炸掉）
    var count = max(top + 1 + _blankExtra, 1);
    // PDF 底圖頁至少全在
    if (_note.backgrounds.isNotEmpty) {
      count = max(count, _note.backgrounds.length);
    }
    return count;
  }

  void _goPage(int i) {
    var target = i.clamp(0, _pageCount);
    if (target == _pageIndex) return;
    // 落到現有範圍外 = 開新空頁（+ 按鈕/快掃下一頁）
    if (target >= _pageCount) {
      _blankExtra += target - _pageCount + 1;
      target = _pageCount - 1;
    }
    setState(() {
      _pageIndex = target;
      _deselect();
      final rects = _pageRects;      if (rects.isNotEmpty) {
        // 跳到該頁頂部（留 96px 工具欄邊距）
        final top = rects[target.clamp(0, rects.length - 1)].top;
        _panOffset =
            _clampPan(Offset(_panOffset.dx, 96 - top * _scale));
      } else {
        // 對齊到新頁頂部附近
        _panOffset = _clampPan(Offset(_panOffset.dx, 0));
      }
    });
    _canvasKey.currentState?.invalidateCache();
    // 跳到的頁若還沒像素（懶加載），後台填上
    _fillMissingBg();
  }

  /// 雙指縱向快掃翻頁（有紙/底圖筆記；慢速雙指仍是平移）。
  void _onPageFlick(int dir) {
    if (_note.pageId == null && _note.backgrounds.isEmpty) return;
    _goPage(_pageIndex + dir);
  }

  // ---------- PDF 頁面管理 ----------
  // backgrounds 下標 = 顯示頁；PageBg.src = 原 PDF 頁碼（null = 空白頁）。
  // 排序/增刪只改列表 + 筆跡頁號重映射，底圖文件按 key 不動，匯出按顯示順序寫。
  bool get _hasPdfPages => _note.backgrounds.isNotEmpty;

  /// 筆跡頁號跟著底圖列表一起搬（move from→to；刪頁時 [drop] 該頁筆跡）。
  List<Stroke> _remapPages(int from, int to, {int? drop}) {
    final out = <Stroke>[];
    for (final s in _note.strokes) {
      var p = s.page;
      if (drop != null) {
        if (p == drop) continue;
        if (p > drop) p -= 1;
      } else if (p == from) {
        p = to;
      } else if (from < to && p > from && p <= to) {
        p -= 1;
      } else if (to < from && p >= to && p < from) {
        p += 1;
      }
      out.add(p == s.page ? s : s.copyWith(page: p));
    }
    return out;
  }

  /// 頁面結構變化後的統一收尾：視角夾回、底圖按鍵重載、重建、存檔。
  void _afterPageStructureChanged(int newFocus) {
    setState(() {
      _pageIndex = newFocus.clamp(0, max(_pageCount - 1, 0));
    });
    _reclampPan();
    _reloadBgImages();
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  void _moveBgPage(int from, int to) {
    final n = _note.backgrounds.length;
    if (from == to || from < 0 || to < 0 || from >= n || to >= n) return;
    _checkpoint();
    setState(() {
      _deselect();
      final bg = _note.backgrounds.removeAt(from);
      _note.backgrounds.insert(to, bg);
      _note.strokes = _remapPages(from, to);
    });
    _afterPageStructureChanged(to);
  }

  /// 在 [at] 處插入空白頁（尺寸套用該位置原頁，末尾則套末頁）。
  void _insertBlankPage(int at) {
    final n = _note.backgrounds.length;
    if (n == 0) return;
    at = at.clamp(0, n);
    _checkpoint();
    setState(() {
      _deselect();
      final ref = _note.backgrounds[at.clamp(0, n - 1)];
      _note.backgrounds
          .insert(at, PageBg(w: ref.w, h: ref.h, key: Note.newId()));
      final out = <Stroke>[];
      for (final s in _note.strokes) {
        out.add(s.page >= at ? s.copyWith(page: s.page + 1) : s);
      }
      _note.strokes = out;
    });
    _afterPageStructureChanged(at);
  }

  void _deleteBgPage(int i) {
    if (_note.backgrounds.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少保留一頁')),
      );
      return;
    }
    _checkpoint();
    setState(() {
      _deselect();
      _note.backgrounds.removeAt(i);
      _note.strokes = _remapPages(0, 0, drop: i);
      // 底圖 PNG 按 key 留著不刪：undo 恢復頁面時底圖還在；
      // 筆記刪除時 `_bg*.png` 一起清。
    });
    _afterPageStructureChanged(min(i, _note.backgrounds.length - 1));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已刪除第 ${i + 1} 頁（可撤銷）')),
      );
    }
  }

  /// 分頁條「＋」：PDF 筆記追加真正的空白頁並跳過去；紙筆記走舊虛擬頁。
  void _addPageEnd() {
    if (!_hasPdfPages) {
      _goPage(_pageCount);
      return;
    }
    _checkpoint();
    setState(() {
      _deselect();
      final last = _note.backgrounds.last;
      _note.backgrounds.add(PageBg(w: last.w, h: last.h, key: Note.newId()));
    });
    _goPage(_note.backgrounds.length - 1);
    _refreshBgImages();
  }

  /// 分頁條「第 X/Y 頁」入口：排序/插入/刪除。
  Future<void> _openPageManager() async {
    if (!_hasPdfPages) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void act(void Function() op) {
            op();
            setSheet(() {});
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text('頁面管理',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _note.backgrounds.length,
                    itemBuilder: (_, i) {
                      final bg = _note.backgrounds[i];
                      final n = _note.backgrounds.length;
                      final count = _note.strokes
                          .where((s) => s.page == i)
                          .length;
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          child: Text('${i + 1}',
                              style: const TextStyle(fontSize: 12)),
                        ),
                        title: Text(
                            '第 ${i + 1} 頁${i == _pageIndex ? '（當前）' : ''}'),
                        subtitle: Text(bg.src == null
                            ? '空白頁 · $count 筆'
                            : 'PDF 第 ${bg.src! + 1} 頁 · $count 筆'),
                        onTap: () {
                          Navigator.pop(ctx);
                          _goPage(i);
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_upward),
                              tooltip: '上移',
                              onPressed: i > 0
                                  ? () => act(() => _moveBgPage(i, i - 1))
                                  : null,
                            ),
                            IconButton(
                              icon: const Icon(Icons.arrow_downward),
                              tooltip: '下移',
                              onPressed: i + 1 < n
                                  ? () => act(() => _moveBgPage(i, i + 1))
                                  : null,
                            ),
                            IconButton(
                              icon: const Icon(Icons.note_add_outlined),
                              tooltip: '在此頁後插入空白頁',
                              onPressed: () =>
                                  act(() => _insertBlankPage(i + 1)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: '刪除此頁（含筆跡，可撤銷）',
                              onPressed: n > 1
                                  ? () => act(() => _deleteBgPage(i))
                                  : null,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('在末尾加空白頁'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _addPageEnd();
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 平移內容區：有紙/底圖為全部堆疊紙框，無限畫布為筆跡包圍盒；
  /// 至少留 120px 在屏內，飛不出去（內容座標，夾時再乘 scale 進屏幕系）。
  Rect get _panContent {
    final rects = _pageRects;
    if (rects.isNotEmpty) {
      var l = double.infinity,
          t = double.infinity,
          r = -double.infinity,
          b = -double.infinity;
      for (final q in rects) {
        if (q.left < l) l = q.left;
        if (q.top < t) t = q.top;
        if (q.right > r) r = q.right;
        if (q.bottom > b) b = q.bottom;
      }
      return Rect.fromLTRB(l, t, r, b);
    }
    return strokesBounds(_note.strokes) ??
        const Rect.fromLTWH(-600, -600, 1200, 1200);
  }

  /// 內容縮小（undo/刪除/回滾）後把視角夾回來，免得停在半空。
  void _reclampPan() {
    final p = _clampPan(_panOffset);
    if (p != _panOffset) setState(() => _panOffset = p);
  }

  Offset _clampPan(Offset p) {
    if (_viewportSize.isEmpty) {
      return Offset(p.dx.clamp(-2500, 2500), p.dy.clamp(-2500, 2500));
    }
    // 全用屏幕座標夾：內容矩形先乘上 scale（以前拿屏 px 的 pan
    // 去比內容 px 的界，scale=1 才對，放大就夾過頭——200% 時紙底到不了）。
    final c = _panContent;
    final sc = Rect.fromLTRB(c.left * _scale, c.top * _scale,
        c.right * _scale, c.bottom * _scale);
    return clampPan(p, _viewportSize, sc);
  }

  void _onPanUpdate(Offset delta) {
    var clipped = false;
    setState(() {
      _panOffset = _clampPan(_panOffset + delta);
      clipped = _syncFocusPage();
    });
    if (clipped) {
      _canvasKey.currentState?.invalidateCache();
      _scheduleAutosave();
    }
  }

  void _onZoomUpdate(double factor, Offset focal) {
    if (factor <= 0 || !factor.isFinite) return;
    final s2 = (_scale * factor).clamp(0.4, 4.0);
    if (s2 == _scale) return;
    final r = s2 / _scale;
    var clipped = false;
    setState(() {
      _scale = s2;
      _panOffset = _clampPan(focal - (focal - _panOffset) * r);
      clipped = _syncFocusPage();
    });
    if (clipped) {
      _canvasKey.currentState?.invalidateCache();
      _scheduleAutosave();
    }
  }

  /// 焦點頁跟著視口中心走（縮圖/分頁指示/落筆頁都以它為準）。
  /// 返回跳頁時是否順手裁掉了舊選區（調用方補 invalidate＋存檔）。
  bool _syncFocusPage() {
    if (_note.pageId == null || _viewportSize.isEmpty) return false;
    final center = Offset(
      (_viewportSize.width / 2 - _panOffset.dx) / _scale,
      (_viewportSize.height / 2 - _panOffset.dy) / _scale,
    );
    final p = pageFromY(center.dy, _pageRects)
        .clamp(0, _pageRects.length - 1);
    if (p != _pageIndex) {
      _pageIndex = p;
      final clipped = _clipDeselected();
      _clearSelection();
      return clipped;
    }
    return false;
  }

  void _resetView() {
    setState(() {
      _panOffset = Offset.zero;
      _scale = 1.0;
    });
  }

  void _setTool(ToolMode t) {
    if (_tool == t) return;
    setState(() {
      _tool = t;
      _deselect();
    });
  }

  /// 橡皮主鈕點按：在「關→當前橡皮→另一橡皮→換回來」之間循環。
  void _cycleEraser() {
    setState(() {
      if (_tool == ToolMode.pen || _tool == ToolMode.lasso) {
        _tool = _lastEraser;
      } else if (_tool == ToolMode.strokeEraser) {
        _tool = ToolMode.pixelEraser;
        _lastEraser = ToolMode.pixelEraser;
      } else {
        _tool = ToolMode.strokeEraser;
        _lastEraser = ToolMode.strokeEraser;
      }
      _deselect();
    });
  }

  void _activateEraser(ToolMode t) {
    setState(() {
      _tool = t;
      _lastEraser = t;
      _deselect();
    });
  }

  /// 工具按鈕：選中態用 filled（主色實心，MD3 標準變體裡最顯眼的一檔）。
  Widget _toolBtn({
    required Widget icon,
    required bool selected,
    required VoidCallback? onPressed,
    VoidCallback? onLongPress,
    required String tooltip,
  }) {
    if (selected) {
      return IconButton.filled(
        onPressed: onPressed,
        onLongPress: onLongPress,
        tooltip: tooltip,
        icon: icon,
      );
    }
    return IconButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      tooltip: tooltip,
      icon: icon,
    );
  }

  void _setView(ViewMode v) {
    if (_view == v) return;
    if (v == ViewMode.zen && _view != ViewMode.zen) {
      _beforeZen = _view; // 記住進來前的樣子，恢復時原樣回去
    }
    setState(() => _view = v);
    widget.onViewChanged?.call(v);
  }

  void _setReadOnly(bool v) {
    setState(() => _readOnly = v);
    widget.settings.readOnly = v;
    widget.settings.save();
  }

  /// 快捷筆：點按即換整套（色/型/粗）。
  void _applyQuickPen(PenPreset p) {
    setState(() {
      _color = p.color;
      _penType = PenTypeLabel.parse(p.type);
      _brushSize = p.size;
      _params.size = p.size;
      _tool = ToolMode.pen;
      _deselect();
    });
    widget.settings.lastColor = p.color;
    widget.settings.lastPenType = p.type;
    widget.settings.lastSize = p.size;
    widget.settings.save();
    _canvasKey.currentState?.invalidateCache();
  }

  /// 筆槽設定：改槽內容並立即套用到當前筆。
  void _editSlot(int i,
      {String? color, PenType? type, double? size}) {
    final pens = widget.settings.quickPens;
    if (i < 0 || i >= pens.length) return;
    final old = pens[i];
    pens[i] = PenPreset(
      color: color ?? old.color,
      type: (type ?? PenTypeLabel.parse(old.type)).name,
      size: size ?? old.size,
    );
    widget.settings.save();
    _applyQuickPen(pens[i]);
  }

  // ---------- 撤銷/重做（快照式，與自動保存無關，落筆即時生效） ----------
  static const int _historyCap = 30;
  final List<_HistoryEntry> _undoStack = [];
  final List<_HistoryEntry> _redoStack = [];
  bool _moveArmed = false; // 拖移流首筆快照一次
  int _activeLayer = 0;

  _HistoryEntry _snapshot() => _HistoryEntry(
        strokes: _note.strokes
            .map((s) => s.copyWith(points: List<NotePoint>.from(s.points)))
            .toList(),
        layerNames: List<String>.from(_note.layerNames),
        hidden: List<int>.from(_note.hiddenLayers),
        active: _activeLayer,
      );

  _HistoryEntry _entryWith(List<Stroke> strokes) => _HistoryEntry(
        strokes: strokes,
        layerNames: List<String>.from(_note.layerNames),
        hidden: List<int>.from(_note.hiddenLayers),
        active: _activeLayer,
      );

  void _restore(_HistoryEntry snap) {
    _note.strokes = snap.strokes
        .map((s) => s.copyWith(points: List<NotePoint>.from(s.points)))
        .toList();
    _note.layerNames = List<String>.from(snap.layerNames);
    _note.hiddenLayers = List<int>.from(snap.hidden);
    _activeLayer =
        snap.active.clamp(0, _note.layerNames.length - 1);
  }

  void _checkpoint() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > _historyCap) _undoStack.removeAt(0);
    _redoStack.clear();
    _moveArmed = false;
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    if (_redoStack.length > _historyCap) _redoStack.removeAt(0);
    setState(() => _restore(_undoStack.removeLast()));
    _pruneSelection();
    _reclampPan();
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    if (_undoStack.length > _historyCap) _undoStack.removeAt(0);
    setState(() => _restore(_redoStack.removeLast()));
    _pruneSelection();
    _reclampPan();
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  void _onStrokeCompleted(Stroke s, int dwellMs) {
    // 新筆落在當前使用中的圖層（隱藏中也照畫，畫完自動取消隱藏）
    if (_note.hiddenLayers.contains(_activeLayer)) {
      _note.hiddenLayers.remove(_activeLayer);
    }
    final sl = s.copyWith(layer: _activeLayer);
    // 形狀修正（僅筆刷筆；收筆前停頓滿 1s 才判，快掃不停留的不碰）
    final out = (widget.settings.shapeSnap &&
            PenTypeLabel.parse(sl.type) == PenType.brush)
        ? snapShape(sl, dwellMs: dwellMs)
        : [sl];
    final didSnap = out.length != 1 || !identical(out.first, sl);
    // 畫到空頁上 = 消化掉它後面的空頁額度
    if (_blankExtra > 0) {
      var m = -1;
      for (final s0 in _note.strokes) {
        if (s0.page > m) m = s0.page;
      }
      if (sl.page > m) _blankExtra = max(0, m + _blankExtra - sl.page);
    }
    _checkpoint();
    setState(() => _note.strokes.addAll(out));
    if (didSnap) {
      // 再壓一筆「原軌跡版」：第一次 undo 回到修正前的樣子，第二次才消失
      _undoStack.add(_entryWith([
        ..._note.strokes.sublist(0, _note.strokes.length - out.length),
        sl,
      ]));
      if (_undoStack.length > _historyCap) _undoStack.removeAt(0);
    }
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  /// 路徑按步長加密（補丟幀間隙），保證拖抹不斷線。
  List<Offset> _densePath(List<Offset> path, double step) {
    if (path.length < 2) return List<Offset>.from(path);
    final out = <Offset>[path.first];
    for (var i = 1; i < path.length; i++) {
      final seg = interpolateGap(out.last, path[i], maxGap: step);
      out.addAll(seg);
    }
    return out;
  }

  /// 按筆畫橡皮即刪（拖抹中逐段回調，頁內座標）：碰到整筆立刻消失；
  /// 整個拖抹會話只在首刪時 checkpoint 一次，一次 undo 整批回來。
  /// 點按空白（沒刪到）不留 checkpoint。
  bool _eraseSessionActive = false;

  void _onStrokeEraseTick(List<Offset> chunk, int page) {
    final hit = <Stroke>{};
    for (final pos in _densePath(chunk, 4)) {
      for (var i = _note.strokes.length - 1; i >= 0; i--) {
        final s = _note.strokes[i];
        if (s.page == page &&
            !_note.hiddenLayers.contains(s.layer) &&
            !hit.contains(s) &&
            hitStroke(s, pos, threshold: _strokeThreshold)) {
          hit.add(s);
        }
      }
    }
    if (hit.isEmpty) return;
    if (!_eraseSessionActive) {
      _checkpoint();
      _eraseSessionActive = true;
    }
    setState(() => _note.strokes.removeWhere((s) => hit.contains(s)));
    _pruneSelection();
    _canvasKey.currentState?.invalidateCache();
  }

  /// 按筆畫橡皮會話結束（抬起/取消）：有刪才存檔結算。
  void _onStrokeEraseEnd() {
    if (!_eraseSessionActive) return;
    _eraseSessionActive = false;
    _reclampPan();
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  /// 像素橡皮按段即刪（拖動中逐段回調）：沿段抹除並斷筆，隱藏圖層不碰；
  /// 整個拖抹只在首刪時 checkpoint，一次 undo 整批回來。
  void _onPixelEraseTick(List<Offset> chunk, int page) {
    final radius = _pixelRadius;
    var cur = List<Stroke>.from(_note.strokes);
    var changed = false;
    for (final pos in _densePath(chunk, radius / 2)) {
      final next = <Stroke>[];
      for (final s in cur) {
        if (s.page != page || _note.hiddenLayers.contains(s.layer)) {
          next.add(s);
          continue;
        }
        final rest = eraseStrokePoints(s, pos, radius);
        if (rest.length == 1 &&
            rest.first.points.length == s.points.length) {
          next.add(s); // 點數不變 = 沒抹到
        } else {
          changed = true;
          next.addAll(rest);
        }
      }
      cur = next;
    }
    if (!changed) return;
    if (!_eraseSessionActive) {
      _checkpoint();
      _eraseSessionActive = true;
    }
    setState(() => _note.strokes = cur);
    _pruneSelection();
    _canvasKey.currentState?.invalidateCache();
  }

  /// 像素橡皮會話結束（抬起/取消）：有刪才存檔結算。
  void _onPixelEraseEnd() {
    if (!_eraseSessionActive) return;
    _eraseSessionActive = false;
    _reclampPan();
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  // ---------- 圈選 ----------
  void _clearSelection() {
    _selected = {};
  }

  void _pruneSelection() {
    _selected.removeWhere((s) =>
        !_note.strokes.contains(s) ||
        _note.hiddenLayers.contains(s.layer));
  }

  void _onLassoCompleted(List<Offset> loop, int page) {
    // 選筆用頁內座標算（虛線框直接按包圍盒畫，不存套索路徑）；
    // 隱藏圖層不圈。舊選區先結算（出紙裁掉）再換新。
    var clipped = false;
    late List<Stroke> hits;
    setState(() {
      clipped = _clipDeselected();
      _moveArmed = false;
      final local = _pageRects.isEmpty
          ? loop
          : [
              for (final p in loop)
                pageLocalOf(p, _pageRects[page.clamp(0, _pageRects.length - 1)]),
            ];
      hits = selectStrokes(
          _note.strokes
              .where((s) =>
                  s.page == page && !_note.hiddenLayers.contains(s.layer))
              .toList(),
          local);
      if (hits.isEmpty) {
        _clearSelection();
      } else {
        _selected = hits.toSet();
        _selectionPage = page;
      }
    });
    if (clipped) {
      _canvasKey.currentState?.invalidateCache();
      _scheduleAutosave();
    }
  }

  void _onSelectionMove(Offset delta) {
    if (_selected.isEmpty) return;
    if (!_moveArmed) {
      _checkpoint();
      _moveArmed = true;
    }
    // 拖曳中不裁紙（路過不算數）；放開才在 onSelectionEnd 結算。
    // moved() 產生新實例，集合跟著換新實例。
    final moved = <Stroke>{};
    final next = <Stroke>[];
    for (final s in _note.strokes) {
      if (_selected.contains(s)) {
        final m = s.moved(delta);
        next.add(m);
        moved.add(m);
      } else {
        next.add(s);
      }
    }
    setState(() {
      _note.strokes = next;
      _selected = moved;
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  /// 圈選旋轉：手柄拖動的角度增量（[center] 為堆疊座標）。
  /// 與移動同一個 undo 作用域（同一手勢只 checkpoint 一次）。
  void _onSelectionRotate(double dAngle, Offset center) {
    if (_selected.isEmpty) return;
    if (!_moveArmed) {
      _checkpoint();
      _moveArmed = true;
    }
    // 筆跡是頁內座標：中心換算到選區頁內再轉
    final off = _pageRects.isEmpty ||
            _selectionPage < 0 ||
            _selectionPage >= _pageRects.length
        ? Offset.zero
        : Offset(0, _pageRects[_selectionPage].top - 24);
    final cLocal = center - off;
    final rotated = <Stroke>{};
    final next = <Stroke>[];
    for (final s in _note.strokes) {
      if (_selected.contains(s)) {
        final r = s.rotated(cLocal, dAngle);
        next.add(r);
        rotated.add(r);
      } else {
        next.add(s);
      }
    }
    setState(() {
      _note.strokes = next;
      _selected = rotated;
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }
  void _onSelectionEnd() {
    // 放開不裁紙：拖出紙的部分留著，還能拖回來或微調；
    // 取消選取（點空白/×/換工具/跳頁/重圈）時 _deselect() 才結算裁掉。
  }

  /// 取消選取結算：有紙/底圖時把選中筆跡出紙的部分裁掉。
  /// 返回是否有裁掉（調用者在 setState 外補 invalidate＋存檔，
  /// 或已在 setState 內時由 _deselect 代勞）。
  /// 與拖移同一個 undo 作用域（這些路徑中間都無 checkpoint）。
  bool _clipDeselected() {
    if (_selected.isEmpty) return false;
    final rect = _clipRectForPage(_selectionPage);
    if (rect == null) return false;
    var clippedAny = false;
    final kept = <Stroke>{};
    final next = <Stroke>[];
    for (final s in _note.strokes) {
      if (!_selected.contains(s)) {
        next.add(s);
        continue;
      }
      final clipped = clipStrokeToRect(s, rect);
      if (clipped.length != 1 ||
          clipped.first.points.length != s.points.length) {
        clippedAny = true;
      }
      next.addAll(clipped);
      kept.addAll(clipped);
    }
    if (clippedAny) {
      _note.strokes = next;
      _selected = kept;
    }
    return clippedAny;
  }

  /// 用戶意義上的「取消選取」：先結算裁紙再清空。
  /// 可直接放進 setState（有裁掉時自動 invalidate＋存檔）。
  void _deselect() {
    _moveArmed = false;
    final clipped = _clipDeselected();
    _clearSelection();
    if (clipped) {
      _canvasKey.currentState?.invalidateCache();
      _scheduleAutosave();
    }
  }

  void _deleteSelection() {
    if (_selected.isEmpty) return;
    _checkpoint();
    setState(() {
      _note.strokes.removeWhere((s) => _selected.contains(s));
      _clearSelection();
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  /// 複製選中（偏移一小段，原選區移到複件上）。
  void _duplicateSelection() {
    if (_selected.isEmpty) return;
    _checkpoint();
    const by = Offset(24, 24);
    final copies = _selected.map((s) => s.moved(by)).toList();
    setState(() {
      _note.strokes.addAll(copies);
      _selected = copies.toSet();
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  // ---------- 圖層 ----------
  /// 使用中圖層：新筆落到這層；點隱藏層會先取消隱藏（不進撤銷）。
  void _setActiveLayer(int i) {
    if (i < 0 || i >= _note.layerNames.length) return;
    setState(() {
      _activeLayer = i;
      _note.hiddenLayers.remove(i);
      _pruneSelection();
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  /// 顯隱開關（不進撤銷，純視圖狀態）。
  void _toggleLayerVisible(int i) {
    if (i < 0 || i >= _note.layerNames.length) return;
    setState(() {
      if (_note.hiddenLayers.contains(i)) {
        _note.hiddenLayers.remove(i);
      } else {
        _note.hiddenLayers.add(i);
      }
      _pruneSelection();
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  void _addLayer() {
    _checkpoint();
    setState(() {
      _note.layerNames.add('圖層 ${_note.layerNames.length + 1}');
      _activeLayer = _note.layerNames.length - 1;
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  Future<void> _renameLayer(int i) async {
    if (i < 0 || i >= _note.layerNames.length) return;
    var value = _note.layerNames[i];
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新命名圖層'),
        content: TextFormField(
          initialValue: value,
          decoration: const InputDecoration(hintText: '圖層名'),
          onChanged: (v) => value = v,
          onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, value.trim()),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    _checkpoint();
    setState(() => _note.layerNames[i] = name);
    _scheduleAutosave();
  }

  List<int> _remapHidden(int drop) => [
        for (final h in _note.hiddenLayers)
          if (h != drop) h > drop ? h - 1 : h,
      ];

  /// 該層并入下層（筆下移，上層整體降一層）。
  void _mergeLayerDown(int i) {
    if (i <= 0 || i >= _note.layerNames.length) return;
    _checkpoint();
    setState(() {
      final next = <Stroke>[];
      for (final s in _note.strokes) {
        if (s.layer == i) {
          next.add(s.copyWith(layer: i - 1));
        } else if (s.layer > i) {
          next.add(s.copyWith(layer: s.layer - 1));
        } else {
          next.add(s);
        }
      }
      _note.strokes = next;
      _note.layerNames.removeAt(i);
      _note.hiddenLayers = _remapHidden(i);
      if (_activeLayer == i) {
        _activeLayer = i - 1;
      } else if (_activeLayer > i) {
        _activeLayer--;
      }
      _pruneSelection();
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  /// 刪除該層（含上面的筆，上層降一層）。只剩一層時不給刪。
  void _deleteLayer(int i) {
    if (_note.layerNames.length <= 1) return;
    if (i < 0 || i >= _note.layerNames.length) return;
    _checkpoint();
    setState(() {
      _note.strokes.removeWhere((s) => s.layer == i);
      final next = <Stroke>[];
      for (final s in _note.strokes) {
        next.add(s.layer > i ? s.copyWith(layer: s.layer - 1) : s);
      }
      _note.strokes = next;
      _note.layerNames.removeAt(i);
      _note.hiddenLayers = _remapHidden(i);
      if (_activeLayer > i) {
        _activeLayer--;
      } else if (_activeLayer == i) {
        _activeLayer = max(0, _note.layerNames.length - 1);
      }
      _pruneSelection();
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  /// 全部合併到使用中圖層。
  void _mergeAllLayers() {
    if (_note.layerNames.length <= 1) return;
    _checkpoint();
    setState(() {
      final keep =
          _activeLayer.clamp(0, _note.layerNames.length - 1);
      final name = _note.layerNames[keep];
      _note.strokes = [
        for (final s in _note.strokes) s.copyWith(layer: keep),
      ];
      _note.layerNames = [name];
      _note.hiddenLayers = [];
      _activeLayer = 0;
      _pruneSelection();
    });
    _canvasKey.currentState?.invalidateCache();
    _scheduleAutosave();
  }

  void _openLayers() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sheetSetState) {
          void refresh() => sheetSetState(() {});
          final n = _note.layerNames.length;
          return SafeArea(
            child: Padding(
              padding:
                  const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('圖層',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: n <= 1
                            ? null
                            : () {
                                _mergeAllLayers();
                                refresh();
                              },
                        icon: const Icon(Icons.merge_outlined, size: 18),
                        label: const Text('合併全部'),
                      ),
                      FilledButton.icon(
                        onPressed: () {
                          _addLayer();
                          refresh();
                        },
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新增'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: n,
                      // 最上層放最上面
                      itemBuilder: (_, k) {
                        final i = n - 1 - k;
                        final active = i == _activeLayer;
                        final hidden =
                            _note.hiddenLayers.contains(i);
                        return ListTile(
                          dense: true,
                          selected: active,
                          selectedTileColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          leading: Icon(
                            active
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 20,
                          ),
                          title: Text(
                            '${_note.layerNames[i]}${active ? '（使用中）' : ''}',
                            style: TextStyle(
                              color: hidden ? Colors.grey : null,
                            ),
                          ),
                          subtitle: Text(
                            '${_note.strokes.where((s) => s.layer == i).length} 筆',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onTap: () {
                            _setActiveLayer(i);
                            refresh();
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  hidden
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 20,
                                ),
                                tooltip: hidden ? '顯示' : '隱藏',
                                onPressed: () {
                                  _toggleLayerVisible(i);
                                  refresh();
                                },
                              ),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, size: 20),
                                onSelected: (v) {
                                  if (v == 'rename') {
                                    _renameLayer(i).then((_) => refresh());
                                  } else if (v == 'merge') {
                                    _mergeLayerDown(i);
                                    refresh();
                                  } else if (v == 'delete') {
                                    _deleteLayer(i);
                                    refresh();
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('重新命名'),
                                  ),
                                  PopupMenuItem(
                                    value: 'merge',
                                    enabled: i > 0,
                                    child: const Text('合併到下層'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    enabled: n > 1,
                                    child: const Text('刪除該層（含筆跡）'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Rect? get _selectionBounds {
    if (_selected.isEmpty) return null;
    var minX = double.infinity,
        minY = double.infinity,
        maxX = -double.infinity,
        maxY = -double.infinity;
    for (final s in _selected) {
      for (final pt in s.points) {
        if (pt.x < minX) minX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y > maxY) maxY = pt.y;
      }
    }
    if (minX == double.infinity) return null;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // ---------- 筆刷（槽位制：三支筆各帶一套設定） ----------
  void _setPixelRadius(double v) {
    setState(() => _pixelRadius = v);
    widget.settings.pixelEraserSize = v;
    widget.settings.save();
  }

  void _setStrokeThreshold(double v) {
    setState(() => _strokeThreshold = v);
    widget.settings.strokeEraserSize = v;
    widget.settings.save();
  }

  Future<void> _addCustomColor(int slot) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定義筆色'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: '#RRGGBB，例如 #20c997',
            prefixIcon: Icon(Icons.color_lens_outlined),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('加入'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    var hex = result.trim();
    if (!hex.startsWith('#')) hex = '#$hex';
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('格式不對，要 #RRGGBB 六位十六進制')),
        );
      }
      return;
    }
    hex = hex.toLowerCase();
    if (!widget.settings.penColors.contains(hex)) {
      widget.settings.penColors.add(hex);
      await widget.settings.save();
    }
    _editSlot(slot, color: hex);
    setState(() {});
  }

  Future<void> _exportPdf() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final bgs = <int, Uint8List>{};
      for (var i = 0; i < _note.backgrounds.length; i++) {
        final bytes = await widget.repo.loadBackground(_note.id, _bgKey(i));
        if (bytes != null) bgs[i] = bytes;
      }
      Uint8List? bytes;
      var vector = false;
      // PDF 底圖筆記：向量匯出（原 PDF + 批註疊加，字保持可选）；
      // 原文件缺失/加密/解析失敗就回退光柵。
      if (_note.backgrounds.isNotEmpty) {
        final orig = await widget.repo.loadOriginalPdf(_note.id);
        if (orig != null) {
          try {
            bytes = buildVectorPdf(
              original: orig,
              strokes: _note.strokes
                  .where((s) => !_note.hiddenLayers.contains(s.layer))
                  .toList(),
              backgrounds: _note.backgrounds,
              hlWidth: _hlWidth,
            );
            vector = true;
          } catch (_) {
            bytes = null;
          }
        }
      }
      bytes ??= await buildNotePdf(_note,
          hlWidth: _hlWidth,
          hiddenLayers: _note.hiddenLayers.toSet(),
          backgrounds: bgs);
      final name = '${Note.sanitizeTitle(_note.title)}_${_note.id}.pdf';
      final where = await savePdfBytes(name, bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'PDF 已匯出：$where${vector ? '（向量批註，字可選）' : ''}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('匯出失敗：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openHistory() async {
    final names = await widget.repo.listHistory(_note.id);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('歷史版本回滾'),
        content: SizedBox(
          width: 320,
          child: names.isEmpty
              ? const Text('尚無歷史快照（保存後自動產生）。')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: names.length,
                  itemBuilder: (_, i) {
                    final name = names[i];
                    return ListTile(
                      title: Text(name),
                      trailing: TextButton(
                        child: const Text('回滾'),
                        onPressed: () async {
                          final restored =
                              await widget.repo.rollback(_note.id, name);
                          if (!mounted) return;
                          setState(() {
                            _note = restored;
                            _activeLayer = _note.layerNames.isEmpty
                                ? 0
                                : _note.layerNames.length - 1;
                          });
                          _titleCtrl.text = _note.title;
                          _reclampPan();
                          _refreshBgImages();
                          _canvasKey.currentState?.invalidateCache();
                          widget.onSaved?.call();
                          // ignore: use_build_context_synchronously
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已回滾到 $name')),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('關閉'),
          ),
        ],
      ),
    );
  }

  /// 紙筆記連續頁面：多頁垂直堆疊，間隙 [_pageGap]。
  static const double _pageGap = 48;

  /// PDF 底圖顯示寬度（內容 px），高度按底圖比例。
  static const double _bgWidth = 800;

  double _pageTop(int i, double hPx) => 24 + i * (hPx + _pageGap);

  Rect _pageRectFor(int i, double wPx, double hPx) =>
      Rect.fromLTWH(24, _pageTop(i, hPx), wPx, hPx);

  /// 當前堆疊紙框（0.._pageCount-1；無限畫布為空）。
  /// PDF 底圖筆記：每頁尺寸來自底圖（超出的空頁套用末頁尺寸）。
  List<Rect> get _pageRects {
    if (_note.backgrounds.isNotEmpty) {
      final out = <Rect>[];
      var y = 24.0;
      for (var i = 0; i < _pageCount; i++) {
        final bg = i < _note.backgrounds.length
            ? _note.backgrounds[i]
            : _note.backgrounds.last;
        final h = _bgWidth * bg.h / bg.w;
        out.add(Rect.fromLTWH(24, y, _bgWidth, h));
        y += h + _pageGap;
      }
      return out;
    }
    final size = PageSize.byId(_note.pageId);
    if (size == null) return const [];
    return [
      for (var i = 0; i < _pageCount; i++)
        _pageRectFor(i, size.wPx, size.hPx),
    ];
  }

  /// 該頁頁內裁剪框（有紙/底圖時；無限畫布返回 null）。
  Rect? _clipRectForPage(int page) {
    final size = PageSize.byId(_note.pageId);
    if (size != null) return Rect.fromLTWH(24, 24, size.wPx, size.hPx);
    if (_note.backgrounds.isNotEmpty) {
      final bg = page < _note.backgrounds.length
          ? _note.backgrounds[page]
          : _note.backgrounds.last;
      return Rect.fromLTWH(24, 24, _bgWidth, _bgWidth * bg.h / bg.w);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final zen = _view == ViewMode.zen;
    final bounds = _selectionBounds;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, cons) {
                _viewportSize = Size(cons.maxWidth, cons.maxHeight);
                return InkCanvas(
                  key: _canvasKey,
                  strokes: _note.strokes,
                  params: _params,
                  color: _color,
                  size: _brushSize,
                  penType: _penType,
                  tool: _tool,
                  palmRejection: widget.settings.palmRejection,
                  onStrokeCompleted: _onStrokeCompleted,
                  onStrokeEraseTick: _onStrokeEraseTick,
                  onStrokeEraseEnd: _onStrokeEraseEnd,
                  onPixelEraseTick: _onPixelEraseTick,
                  onPixelEraseEnd: _onPixelEraseEnd,
                  panOffset: _panOffset,
                  scale: _scale,
                  onPanUpdate: _onPanUpdate,
                  onZoomUpdate: _onZoomUpdate,
                  onZoomEnd: () async {
                    await _maybeUpgradeBg();
                    // 缩放时看到的缺页（升级只管内存不管盘），顺手落盘
                    _fillMissingBg();
                  },
                  onLassoCompleted: _onLassoCompleted,
                  onSelectionMove: _onSelectionMove,
                  onSelectionRotate: _onSelectionRotate,
                  onSelectionEnd: _onSelectionEnd,
                  onDeselect: () => setState(_deselect),
                  onPageFlick: _onPageFlick,
                  onTwoFingerDoubleTap: _undo,
                  onTwoFingerTripleTap: _redo,
                  selectionBounds: bounds,
                  selectionPage: _selectionPage,
                  selectionRect: _selectionRect,
                  hiddenLayers: _note.hiddenLayers,
                  pageRects: _pageRects,
                  pixelRadius: _pixelRadius,
                  strokeThreshold: _strokeThreshold,
                  hlWidth: _hlWidth,
                  hlAlpha: _hlAlpha,
                  readOnly: _readOnly,
                  shapeSnap: widget.settings.shapeSnap,
                );
              },
            ),
          ),
          // 沉浸恢復鈕（沉浸時全場只剩它）
          if (zen)
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: Opacity(
                  opacity: 0.6,
                    child: FloatingActionButton.small(
                      heroTag: 'zen',
                      onPressed: () => _setView(_beforeZen),
                      tooltip: '退出沉浸（回到之前樣子）',
                      child: const Icon(Icons.visibility),
                    ),
                ),
              ),
            ),
          // 圈選操作條
          if (!zen && bounds != null)
            Positioned(
              left: (bounds.left * _scale + _panOffset.dx)
                  .clamp(8, double.infinity),
              top: (bounds.top * _scale + _panOffset.dy - 52)
                  .clamp(8, double.infinity),
              child: Card(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: '複製選中',
                      onPressed: _duplicateSelection,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '刪除選中',
                      onPressed: _deleteSelection,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '取消選擇',
                      onPressed: () => setState(_deselect),
                    ),
                  ],
                ),
              ),
            ),
          // 縮放指示（≠100% 時顯示，點按復位）
          if (!zen && (_scale - 1.0).abs() > 0.01)
            Positioned(
              bottom: 12,
              right: 12,
              child: ActionChip(
                label: Text('${(_scale * 100).round()}%'),
                tooltip: '點按復位視角',
                onPressed: _resetView,
              ),
            ),
          // 底部分頁條（有紙/底圖時才有頁的概念；沉浸時隱藏）
          if ((_note.pageId != null || _note.backgrounds.isNotEmpty) && !zen)
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Center(
                child: Card(
                  color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left),
                          tooltip: '上一頁',
                          onPressed: _pageIndex > 0
                              ? () => _goPage(_pageIndex - 1)
                              : null,
                        ),
                        if (_hasPdfPages)
                          Tooltip(
                            message: '頁面管理（排序/插入/刪除）',
                            child: TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: _openPageManager,
                              child: Text(
                                  '第 ${_pageIndex + 1}/$_pageCount 頁'),
                            ),
                          )
                        else
                          Text('第 ${_pageIndex + 1}/$_pageCount 頁'),
                        IconButton(
                          icon: const Icon(Icons.chevron_right),
                          tooltip: '下一頁',
                          onPressed: _pageIndex + 1 < _pageCount
                              ? () => _goPage(_pageIndex + 1)
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: '新增頁',
                          onPressed: _addPageEnd,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // 頂部懸浮半透明工具欄（沉浸時隱藏）
          if (!zen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Center(
                    child: Card(
                      color:
                          scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 140,
                                child: TextField(
                                  controller: _titleCtrl,
                                  decoration: const InputDecoration(
                                    hintText: '標題',
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                  onChanged: (_) => _scheduleAutosave(),
                                ),
                              ),
                              // 三支筆刷鈕：點按整套切換（色/型/粗），長按/右鍵開該支的設定。
                              for (var qi = 0;
                                  qi <
                                      widget.settings.quickPens.length.clamp(
                                          0, _slotMenus.length);
                                  qi++)
                                Listener(
                                  behavior: HitTestBehavior.translucent,
                                  onPointerDown: (e) {
                                    if (e.buttons & kSecondaryMouseButton !=
                                        0) {
                                      _slotMenus[qi].open();
                                    }
                                  },
                                  child: MenuAnchor(
                                    controller: _slotMenus[qi],
                                    menuChildren: [_slotPanel(qi)],
                                    child: _toolBtn(
                                      icon: PenColorButton(
                                        hexColor: widget.settings
                                            .quickPens[qi].color,
                                        penType: PenTypeLabel.parse(widget
                                            .settings
                                            .quickPens[qi]
                                            .type),
                                        size: 24,
                                      ),
                                      selected: _tool == ToolMode.pen &&
                                          _color ==
                                              widget.settings
                                                  .quickPens[qi].color &&
                                          _penType ==
                                              PenTypeLabel.parse(widget
                                                  .settings
                                                  .quickPens[qi]
                                                  .type) &&
                                          _brushSize ==
                                              widget.settings
                                                  .quickPens[qi].size,
                                      onPressed: () => _applyQuickPen(
                                          widget.settings.quickPens[qi]),
                                      onLongPress: () {
                                        if (!_slotMenus[qi].isOpen) {
                                          _slotMenus[qi].open();
                                        }
                                      },
                                      tooltip:
                                          '筆刷${qi + 1}（點按切換，長按/右鍵調設定）',
                                    ),
                                  ),
                                ),
                              // 橡皮單按鈕：點一下用當前橡皮，再點切換；
                              // 長按（觸屏）/ 右鍵（桌面）開二級菜單明確選擇 + 調尺寸。
                              Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerDown: (e) {
                                  if (e.buttons & kSecondaryMouseButton !=
                                      0) {
                                    _eraserMenu.open();
                                  }
                                },
                                child: MenuAnchor(
                                controller: _eraserMenu,
                                menuChildren: [
                                  MenuItemButton(
                                    leadingIcon: const StrokeEraserIcon(),
                                    trailingIcon:
                                        _tool == ToolMode.strokeEraser
                                            ? const Icon(Icons.check)
                                            : null,
                                    onPressed: () {
                                      _eraserMenu.close();
                                      _activateEraser(
                                          ToolMode.strokeEraser);
                                    },
                                    child: const Text('按筆畫擦除'),
                                  ),
                                  MenuItemButton(
                                    leadingIcon: const PixelEraserIcon(),
                                    trailingIcon:
                                        _tool == ToolMode.pixelEraser
                                            ? const Icon(Icons.check)
                                            : null,
                                    onPressed: () {
                                      _eraserMenu.close();
                                      _activateEraser(
                                          ToolMode.pixelEraser);
                                    },
                                    child: const Text('像素擦除'),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12),
                                    child: SizedBox(
                                      width: 220,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            children: [
                                              const Text('按筆畫',
                                                  style: TextStyle(
                                                      fontSize: 12)),
                                              Expanded(
                                                child: Slider(
                                                  min: 6,
                                                  max: 30,
                                                  value: _strokeThreshold
                                                      .clamp(6, 30),
                                                  onChanged:
                                                      _setStrokeThreshold,
                                                ),
                                              ),
                                              Text(
                                                _strokeThreshold
                                                    .toStringAsFixed(0),
                                                style: const TextStyle(
                                                    fontSize: 12),
                                              ),
                                            ],
                                          ),
                                          Row(
                                            children: [
                                              const Text('像素',
                                                  style: TextStyle(
                                                      fontSize: 12)),
                                              Expanded(
                                                child: Slider(
                                                  min: 4,
                                                  max: 30,
                                                  value: _pixelRadius
                                                      .clamp(4, 30),
                                                  onChanged:
                                                      _setPixelRadius,
                                                ),
                                              ),
                                              Text(
                                                _pixelRadius
                                                    .toStringAsFixed(0),
                                                style: const TextStyle(
                                                    fontSize: 12),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  MenuItemButton(
                                    leadingIcon: const Icon(Icons.close),
                                    onPressed: () {
                                      _eraserMenu.close();
                                      _setTool(ToolMode.pen);
                                    },
                                    child: const Text('關閉橡皮'),
                                  ),
                                ],
                                child: _toolBtn(
                                  icon: _lastEraser == ToolMode.pixelEraser
                                      ? const PixelEraserIcon()
                                      : const StrokeEraserIcon(),
                                  selected: _tool ==
                                          ToolMode.strokeEraser ||
                                      _tool == ToolMode.pixelEraser,
                                  onPressed: () {
                                    if (_eraserMenu.isOpen) {
                                      _eraserMenu.close();
                                    } else {
                                      _cycleEraser();
                                    }
                                  },
                                  // 長按開菜單（桌面右鍵/觸屏長按都行）
                                  onLongPress: () {
                                    if (!_eraserMenu.isOpen) {
                                      _eraserMenu.open();
                                    }
                                  },
                                  tooltip: '橡皮擦（點按切換，長按/右鍵選模式）',
                                ),
                              ),
                              ),
                              _toolBtn(
                                icon: const LassoIcon(),
                                selected: _tool == ToolMode.lasso,
                                onPressed: () => _setTool(ToolMode.lasso),
                                tooltip: '圈選（框住移動/旋轉/複製/刪除）',
                              ),
                              IconButton(
                                icon: const Icon(Icons.layers_outlined),
                                onPressed: _openLayers,
                                tooltip:
                                    '圖層（${_note.layerNames[_activeLayer.clamp(0, _note.layerNames.length - 1)]}使用中）',
                              ),
                              IconButton(
                                icon: const Icon(Icons.undo),
                                onPressed: _undoStack.isEmpty ? null : _undo,
                                tooltip: '撤銷',
                              ),
                              IconButton(
                                icon: const Icon(Icons.redo),
                                onPressed: _redoStack.isEmpty ? null : _redo,
                                tooltip: '重做',
                              ),
                              _toolBtn(
                                icon: Icon(_view == ViewMode.fullscreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen),
                                selected:
                                    _view == ViewMode.fullscreen,
                                onPressed: () => _setView(
                                    _view == ViewMode.fullscreen
                                        ? ViewMode.normal
                                        : ViewMode.fullscreen),
                                tooltip: '全屏（留工具欄+頁碼）',
                              ),
                              IconButton(
                                icon: const Icon(
                                    Icons.center_focus_strong),
                                onPressed: _panOffset == Offset.zero &&
                                        _scale == 1.0
                                    ? null
                                    : _resetView,
                                tooltip: '重置視角',
                              ),
                              // 三個點：沉浸、歷史版本這種不常用的放這裡
                              MenuAnchor(
                                controller: _moreMenu,
                                menuChildren: [
                                  MenuItemButton(
                                    leadingIcon: const Icon(
                                        Icons.visibility_off),
                                    trailingIcon: _view == ViewMode.zen
                                        ? const Icon(Icons.check)
                                        : null,
                                    onPressed: () {
                                      _moreMenu.close();
                                      _setView(ViewMode.zen);
                                    },
                                    child: const Text('沉浸模式'),
                                  ),
                                  MenuItemButton(
                                    leadingIcon:
                                        const Icon(Icons.history),
                                    onPressed: () {
                                      _moreMenu.close();
                                      _openHistory();
                                    },
                                    child: const Text('歷史版本'),
                                  ),
                                  MenuItemButton(
                                    leadingIcon: const Icon(
                                        Icons.pan_tool_outlined),
                                    trailingIcon: _readOnly
                                        ? const Icon(Icons.check)
                                        : null,
                                    onPressed: () {
                                      _moreMenu.close();
                                      _setReadOnly(!_readOnly);
                                    },
                                    child: const Text('唯讀（單指滑動）'),
                                  ),
                                ],
                                child: IconButton(
                                  icon: const Icon(Icons.more_vert),
                                  onPressed: () {
                                    if (_moreMenu.isOpen) {
                                      _moreMenu.close();
                                    } else {
                                      _moreMenu.open();
                                    }
                                  },
                                  tooltip: '更多',
                                ),
                              ),
                              IconButton(
                                icon:
                                    const Icon(Icons.picture_as_pdf_outlined),
                                onPressed: _exportPdf,
                                tooltip: '匯出 PDF',
                              ),
                              IconButton(
                                icon: const Icon(Icons.save_outlined),
                                onPressed: _doSave,
                                tooltip: '立即保存',
                              ),
                              if (_saving || _exporting)
                                const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 筆槽設定面板：筆型 + 調色盤 + 大小（改完立即套用到當前筆）。
  Widget _slotPanel(int slot) {
    final pens = widget.settings.penColors;
    final sp = widget.settings.quickPens[slot];
    final spType = PenTypeLabel.parse(sp.type);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 264,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('筆刷${slot + 1}設定',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<PenType>(
              segments: const [
                ButtonSegment(
                    value: PenType.brush, label: Text('筆刷')),
                ButtonSegment(
                    value: PenType.dashed, label: Text('虛線')),
                ButtonSegment(
                    value: PenType.highlighter, label: Text('螢光')),
              ],
              selected: {spType},
              onSelectionChanged: (s) => _editSlot(slot, type: s.first),
            ),
            const SizedBox(height: 8),
            const Text('筆色', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in pens)
                  InkWell(
                    onTap: () => _editSlot(slot, color: c),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _parseColor(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == sp.color
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.withValues(alpha: 0.4),
                          width: c == sp.color ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _addCustomColor(slot),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('自定義'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    widget.settings.penColors =
                        List<String>.from(AppSettings.defaultPens);
                    await widget.settings.save();
                    setState(() {});
                  },
                  child: const Text('重設'),
                ),
              ],
            ),
            const Divider(),
            Row(
              children: [
                const Text('大小',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(sp.size.toStringAsFixed(1)),
              ],
            ),
            Slider(
              min: 1.0,
              max: 16.0,
              value: sp.size.clamp(1.0, 16.0),
              onChanged: (v) => _editSlot(slot, size: v),
            ),
            if (spType == PenType.highlighter) ...[
              Row(
                children: [
                  const Text('螢光透明度',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text(_hlAlpha.toStringAsFixed(2)),
                ],
              ),
              Slider(
                min: 0.1,
                max: 0.8,
                value: _hlAlpha.clamp(0.1, 0.8),
                onChanged: (v) {
                  setState(() => _hlAlpha = v);
                  widget.settings.lastHlAlpha = v;
                  widget.settings.save();
                  _canvasKey.currentState?.invalidateCache();
                },
              ),
              Row(
                children: [
                  const Text('螢光寬度',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${_hlWidth.toStringAsFixed(1)}×'),
                ],
              ),
              Slider(
                min: 2.0,
                max: 6.0,
                value: _hlWidth.clamp(2.0, 6.0),
                onChanged: (v) {
                  setState(() => _hlWidth = v);
                  widget.settings.lastHlWidth = v;
                  widget.settings.save();
                  _canvasKey.currentState?.invalidateCache();
                },
              ),
            ],
            Row(
              children: [
                const Text('直線箭頭修正', style: TextStyle(fontSize: 13)),
                const Spacer(),
                Switch(
                  value: widget.settings.shapeSnap,
                  onChanged: (v) {
                    setState(
                        () => widget.settings.shapeSnap = v);
                    widget.settings.save();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.parse(h, radix: 16));
  }
}

/// 縮圖渲染：把筆跡畫到小圖並編碼 PNG（列表頁預覽用）。
/// PDF 底圖筆記傳入該頁底圖（已解碼）+ 頁內區域，底圖墊底。
Future<Uint8List?> renderThumbnail(List<Stroke> strokes,
    {double maxWidth = 240,
    double hlWidth = 3.0,
    StrokeParams? params,
    ui.Image? bgImage,
    Rect? bgRect}) async {
  ui.Image? bg = bgImage;
  double minX = double.infinity,
      minY = double.infinity,
      maxX = -double.infinity,
      maxY = -double.infinity;
  var margin = 10.0;
  if (bg != null && bgRect != null) {
    minX = bgRect.left;
    minY = bgRect.top;
    maxX = bgRect.right;
    maxY = bgRect.bottom;
    margin = 0;
  } else {
    if (strokes.isEmpty) return null;
    for (final s in strokes) {
      for (final pt in s.points) {
        if (pt.x < minX) minX = pt.x;
        if (pt.y < minY) minY = pt.y;
        if (pt.x > maxX) maxX = pt.x;
        if (pt.y > maxY) maxY = pt.y;
      }
    }
  }
  final w = (maxX - minX + margin * 2).clamp(10, 2000).toDouble();
  final h = (maxY - minY + margin * 2).clamp(10, 2000).toDouble();
  final scale = maxWidth / w;
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.scale(scale, scale);
  canvas.translate(-minX + margin, -minY + margin);
  canvas.drawRect(
    ui.Rect.fromLTWH(minX - margin, minY - margin, w, h),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  if (bg != null && bgRect != null) {
    canvas.drawImageRect(
      bg,
      ui.Rect.fromLTWH(
          0, 0, bg.width.toDouble(), bg.height.toDouble()),
      ui.Rect.fromLTWH(minX, minY, maxX - minX, maxY - minY),
      ui.Paint(),
    );
  }
  paintStrokesLayered(canvas, strokes, hlWidth: hlWidth, params: params);
  final pic = rec.endRecording();
  final img = await pic.toImage(
      (w * scale).round().clamp(1, 1024), (h * scale).round().clamp(1, 1024));
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  pic.dispose();
  img.dispose();
  return bytes?.buffer.asUint8List();
}
