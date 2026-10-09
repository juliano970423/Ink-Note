import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../import/pdf_import.dart';
import '../models/note.dart';
import '../settings/app_settings.dart';
import '../storage/note_store.dart';
import 'editor_page.dart';
import 'settings_page.dart';

/// 筆記列表頁：標題 + updatedAt + 縮圖預覽。點列表頭「新筆記」新建（可選頁面尺寸）。
/// 寬螢幕（>900px）列表-編輯雙欄佈局；側欄可折疊；全屏/沉浸時收起左側。
class HomePage extends StatefulWidget {
  final NoteStore repo;
  final AppSettings settings;

  const HomePage({super.key, required this.repo, required this.settings});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Note> _notes = [];
  List<String> _folders = [];
  String? _selectedId;
  bool _loading = true;
  String _query = '';
  String _filterFolder = ''; // '' = 全部
  ViewMode _view = ViewMode.normal; // 寬屏全屏/沉浸：收起 rail+列表
  int _railIndex = 0; // 0 筆記 / 1 設置（寬屏右側切換）
  // 寬螢幕編輯器正在編輯的實例：與 _reload 解耦，自動保存不重建編輯器。
  Note? _openNote;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final notes = await widget.repo.listAll();
    final folders = await widget.repo.listFolders();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _folders = folders;
      _loading = false;
      if (_filterFolder.isNotEmpty && !_folders.contains(_filterFolder)) {
        _filterFolder = '';
      }
      if (_selectedId != null &&
          !_notes.any((n) => n.id == _selectedId)) {
        _selectedId = null;
      }
    });
  }

  List<Note> get _filtered {
    Iterable<Note> notes = _notes;
    if (_filterFolder.isNotEmpty) {
      notes = notes.where((n) => n.folder == _filterFolder);
    }
    if (_query.isNotEmpty) {
      notes = notes.where(
          (n) => n.title.toLowerCase().contains(_query.toLowerCase()));
    }
    return notes.toList();
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(settings: widget.settings),
      ),
    ).then((_) => setState(() {}));
  }

  /// 新建：先選頁面尺寸（A4/A5/B5/Letter/無限畫布），再建檔。
  Future<void> _create() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('新筆記：頁面尺寸'),
        children: [
          for (final s in PageSize.all)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s.id),
              child: Text(
                  '${s.label}（${s.wMm.toStringAsFixed(0)}×${s.hMm.toStringAsFixed(0)}mm）'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__infinite__'),
            child: const Text('無限畫布'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__pdf__'),
            child: const Text('匯入 PDF…'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return; // null = 對話框被取消
    // ignore: avoid_print
    print('INKDBG create picked=$picked');
    if (picked == '__pdf__') {
      await _importPdf();
      return;
    }
    final String? pageId = picked == '__infinite__' ? null : picked;
    final now = DateTime.now().toUtc();
    final note = Note(
      id: Note.newId(),
      title: '未命名筆記',
      createdAt: now,
      updatedAt: now,
      folder: _filterFolder,
      pageId: pageId,
    );
    await widget.repo.save(note);
    // ignore: avoid_print
    print('INKDBG create saved id=${note.id}');
    await _openNewNote(note);
    // ignore: avoid_print
    print('INKDBG create opened');
  }

  /// 建檔後開編輯器（新建/匯入共用）。
  Future<void> _openNewNote(Note note) async {
    await _reload();
    if (!mounted) return;
    setState(() {
      _selectedId = note.id;
      _openNote = note;
      _view = ViewMode.normal;
    });
    if (MediaQuery.of(context).size.width <= 900) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _NarrowEditor(
            repo: widget.repo,
            settings: widget.settings,
            note: note,
            onSaved: _reload,
          ),
        ),
      );
      _reload();
    }
  }

  /// 匯入 PDF：選檔 → 逐頁渲染底圖 → 建底圖筆記。
  Future<void> _importPdf() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('正在打開 PDF（其餘頁面後台載入）…')),
          ],
        ),
      ),
    );
    List<({int w, int h, int src})> metas;
    List<RenderedPdfPage> first;
    try {
      // 盒子元数据极快：先建全部页条目，秒开编辑器
      metas = pageBoxMetas(bytes);
      if (metas.isEmpty) throw StateError('no pages');
      // 只渲第一页（首屏），其余编辑器打开后后台填
      first = await renderPdfPages(bytes, maxPages: 1);
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 打不開：$e')),
        );
      }
      return;
    }
    if (!mounted) return;
    final now = DateTime.now().toUtc();
    var title = file.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false), '');
    if (title.trim().isEmpty) title = '未命名筆記';
    final note = Note(
      id: Note.newId(),
      title: Note.sanitizeTitle(title),
      createdAt: now,
      updatedAt: now,
      folder: _filterFolder,
      backgrounds: [
        for (final m in metas)
          PageBg(w: m.w, h: m.h, key: Note.newId(), src: m.src),
      ],
    );
    await widget.repo.save(note);
    await widget.repo.saveOriginalPdf(note.id, bytes);
    // 第一页有像素就存；没有也开（编辑器后台会填）
    if (first.isNotEmpty) {
      await widget.repo.saveBackground(
          note.id, note.backgrounds.first.key, first.first.png);
    }
    if (!mounted) return;
    Navigator.pop(context);
    await _openNewNote(note);
  }

  Future<void> _open(Note note) async {
    setState(() => _selectedId = note.id);
    if (MediaQuery.of(context).size.width <= 900) {
      final fresh = await widget.repo.load(note.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _NarrowEditor(
            repo: widget.repo,
            settings: widget.settings,
            note: fresh,
            onSaved: _reload,
          ),
        ),
      );
      _reload();
    } else {
      final fresh = await widget.repo.load(note.id);
      if (!mounted) return;
      setState(() {
        final i = _notes.indexWhere((n) => n.id == fresh.id);
        if (i >= 0) _notes[i] = fresh;
        _openNote = fresh;
        _view = ViewMode.normal;
      });
    }
  }

  Future<void> _moveNote(Note n, String target) async {
    final fresh = await widget.repo.load(n.id);
    fresh.folder = Note.sanitizeFolder(target);
    await widget.repo.save(fresh);
    if (_openNote?.id == n.id) _openNote!.folder = fresh.folder;
    await _reload();
  }

  Future<void> _moveDialog(Note n) async {
    final options = ['', ..._folders];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('移動「${n.title}」到…'),
        children: [
          for (final f in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, f),
              child: Text(f.isEmpty ? '根目錄（未分類）' : f),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _moveNote(n, picked);
  }

  Future<void> _newFolderDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新資料夾'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '資料夾名稱'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('建立'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final folder = Note.sanitizeFolder(name);
    if (folder.isEmpty) return;
    // 資料夾以筆記存在為準，這裡直接切換篩選；
    // 第一篇筆記移入/建入時目錄自動產生。
    if (!mounted) return;
    setState(() {
      if (!_folders.contains(folder)) _folders.add(folder);
      _filterFolder = folder;
    });
  }

  Future<void> _manageFoldersDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('管理資料夾'),
          content: SizedBox(
            width: 300,
            child: _folders.isEmpty
                ? const Text('還沒有資料夾。')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _folders.length,
                    itemBuilder: (_, i) {
                      final f = _folders[i];
                      final count =
                          _notes.where((n) => n.folder == f).length;
                      return ListTile(
                        title: Text('$f（$count 篇）'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: '重新命名',
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _renameFolder(f);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: '刪除（筆記搬回根目錄）',
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _deleteFolder(f);
                              },
                            ),
                          ],
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
      ),
    );
  }

  Future<void> _renameFolder(String old) async {
    final ctrl = TextEditingController(text: old);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新命名資料夾'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final folder = Note.sanitizeFolder(name);
    if (folder.isEmpty || folder == old) return;
    for (final n in _notes.where((n) => n.folder == old)) {
      final fresh = await widget.repo.load(n.id);
      fresh.folder = folder;
      await widget.repo.save(fresh);
      if (_openNote?.id == n.id) _openNote!.folder = folder;
    }
    await _reload();
    if (!mounted) return;
    setState(() => _filterFolder = folder);
  }

  Future<void> _deleteFolder(String folder) async {
    for (final n in _notes.where((n) => n.folder == folder)) {
      final fresh = await widget.repo.load(n.id);
      fresh.folder = '';
      await widget.repo.save(fresh);
      if (_openNote?.id == n.id) _openNote!.folder = '';
    }
    try {
      await widget.repo.deleteFolder(folder);
    } catch (_) {}
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 900;
        if (wide) return _buildWide();
        // 窄屏：設置走 AppBar 右上圖標（MD3：NavigationBar 只用於多個頂級目的地）。
        return Scaffold(
          appBar: AppBar(
            title: const Text('Ink Notes'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '設置',
                onPressed: _openSettings,
              ),
            ],
          ),
          body: _listPane(),
        );
      },
    );
  }

  Widget _buildWide() {
    // 注意：Row 結構在任何模式下保持不變（只用 Visibility 收起），
    // 否則 EditorPage 的坑位一變就會被銷毀重建（視圖/頁碼/畫布快取全丟）。
    // 全屏/沉浸時 rail+列表整排往左收掉，只剩畫布。
    return Scaffold(
      body: Row(
        children: [
          _keepAlive(
            visible: !_chromeHidden,
            child: NavigationRail(
              selectedIndex: _railIndex,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) =>
                  setState(() => _railIndex = i),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.note_outlined),
                  selectedIcon: Icon(Icons.note),
                  label: Text('筆記'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('設置'),
                ),
              ],
            ),
          ),
          _keepAlive(
            visible: !_chromeHidden,
            child: const VerticalDivider(width: 1),
          ),
          _keepAlive(
            visible: !_chromeHidden,
            child: SizedBox(width: 340, child: _listPane()),
          ),
          _keepAlive(
            visible: !_chromeHidden,
            child: const VerticalDivider(width: 1),
          ),
          // IndexedStack 兩邊狀態都留著，切來切去不丟編輯器狀態
          Expanded(
            child: IndexedStack(
              index: _railIndex,
              children: [
                _editorPane(),
                SettingsPage(settings: widget.settings),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 收起時保狀態、不佔位（坑位不變，右側編輯器 state 不會被重建）。
  /// 全屏/沉浸時 rail+列表整排往左收掉，只剩畫布。
  bool get _chromeHidden => _view != ViewMode.normal;

  Widget _keepAlive({required bool visible, required Widget child}) =>
      Visibility(
        visible: visible,
        maintainState: true,
        maintainAnimation: false,
        maintainSize: false,
        child: child,
      );

  Widget _listPane() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: SearchBar(
            hintText: '搜尋筆記',
            leading: const Icon(Icons.search),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        // 新筆記按鈕放列表頭：右下角只留新增頁，不打架。
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('新筆記'),
            ),
          ),
        ),
        // 資料夾篩選列
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: FilterChip(
                  label: const Text('全部'),
                  selected: _filterFolder.isEmpty,
                  onSelected: (_) =>
                      setState(() => _filterFolder = ''),
                ),
              ),
              for (final f in _folders)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: FilterChip(
                    label: Text(f),
                    selected: _filterFolder == f,
                    onSelected: (_) =>
                        setState(() => _filterFolder = f),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: '新資料夾',
                onPressed: _newFolderDialog,
              ),
              IconButton(
                icon: const Icon(Icons.folder_outlined),
                tooltip: '管理資料夾',
                onPressed: _manageFoldersDialog,
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: _filtered.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 80),
                      Center(child: Text('這裡空空如也，點 + 新建一篇吧')),
                    ],
                  )
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) {
                      final n = _filtered[i];
                      return _noteCard(n);
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _noteCard(Note n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(n),
          child: Row(
            children: [
              FutureBuilder<Uint8List?>(
                future: _thumbBytes(n.id),
                builder: (ctx, snap) {
                  final bytes = snap.data;
                  if (bytes != null && bytes.isNotEmpty) {
                    return Image.memory(
                      bytes,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    );
                  }
                  return Container(
                    width: 72,
                    height: 72,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: const Icon(Icons.draw_outlined),
                  );
                },
              ),
              Expanded(
                child: ListTile(
                  title: Text(n.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${n.updatedAt.toLocal().toString().substring(0, 16)} · ${n.strokes.length} 筆'
                    '${n.folder.isNotEmpty ? ' · ${n.folder}' : ''}',
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (v) async {
                      if (v == 'move') {
                        await _moveDialog(n);
                      } else if (v == 'delete') {
                        await widget.repo.delete(n.id);
                        _reload();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'move', child: Text('移動到…')),
                      PopupMenuItem(
                          value: 'delete', child: Text('刪除')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<Uint8List?> _thumbBytes(String id) async {
    try {
      return await widget.repo.loadThumbnail(id);
    } catch (_) {
      return null;
    }
  }

  Widget _editorPane() {
    // key 只用 id：自動保存只刷新列表，絕不重建編輯器。
    final open = _openNote;
    if (open == null || open.id != _selectedId) {
      return const Center(child: Text('從左側選擇一篇筆記，或新建一篇'));
    }
    if (!_notes.any((n) => n.id == open.id)) {
      return const Center(child: Text('筆記已刪除'));
    }
    return EditorPage(
      key: ValueKey('editor-${open.id}'),
      repo: widget.repo,
      settings: widget.settings,
      note: open,
      onSaved: _reload,
      onViewChanged: (v) => setState(() => _view = v),
    );
  }
}

/// 窄屏編輯路由：全屏/沉浸時連 AppBar 一起藏（返回靠手勢/恢復鈕）。
class _NarrowEditor extends StatefulWidget {
  final NoteStore repo;
  final AppSettings settings;
  final Note note;
  final VoidCallback? onSaved;

  const _NarrowEditor({
    required this.repo,
    required this.settings,
    required this.note,
    this.onSaved,
  });

  @override
  State<_NarrowEditor> createState() => _NarrowEditorState();
}

class _NarrowEditorState extends State<_NarrowEditor> {
  ViewMode _view = ViewMode.normal;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _view == ViewMode.normal ? AppBar() : null,
      body: EditorPage(
        repo: widget.repo,
        settings: widget.settings,
        note: widget.note,
        onSaved: widget.onSaved,
        onViewChanged: (v) => setState(() => _view = v),
      ),
    );
  }
}
