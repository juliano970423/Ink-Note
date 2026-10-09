import 'package:flutter/material.dart';

import 'settings/app_settings.dart';
import 'storage/note_store.dart';
import 'storage/store_provider.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面/移動端走文件存儲，Web 走內存實現（見 store_provider）。
  final NoteStore repo = await createStore();
  final settings = AppSettings();
  await settings.load();
  runApp(InkNotesApp(repo: repo, settings: settings));
}

class InkNotesApp extends StatelessWidget {
  final NoteStore repo;
  final AppSettings settings;

  const InkNotesApp({super.key, required this.repo, required this.settings});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3B5BFD);
    return MaterialApp(
      title: 'Ink Notes',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system, // 跟隨系統深色/淺色
      home: HomePage(repo: repo, settings: settings),
    );
  }
}
