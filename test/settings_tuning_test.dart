import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_notes/settings/app_settings.dart';
import 'package:ink_notes/ui/settings_page.dart';

/// 手感調參住在設置頁（maxSpeed/emaWeight/thinning/streamline），
/// 不再有編輯器浮動面板。
void main() {
  testWidgets('設置頁含四項手感參數且可調', (tester) async {
    final settings = AppSettings();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(settings: settings)),
    );
    await tester.pumpAndSettle();
    for (final label in ['maxSpeed', 'emaWeight', 'thinning', 'streamline']) {
      expect(find.textContaining(label), findsOneWidget);
    }
    // 拖 thinning 滑桿 → deviceProfile 跟著變（編輯器經 didUpdateWidget 實時同步）
    final sliders = find.byType(Slider);
    expect(sliders, findsNWidgets(4));
    await tester.drag(sliders.at(2), const Offset(60, 0));
    await tester.pump();
    expect(settings.deviceProfile.thinning, isNot(0.6));
  });
}
