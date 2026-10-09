import 'package:flutter/material.dart';

import '../settings/app_settings.dart';

/// 設置頁：手感調參（maxSpeed/emaWeight/thinning/streamline）+ palmRejection。
class SettingsPage extends StatefulWidget {
  final AppSettings settings;

  const SettingsPage({super.key, required this.settings});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final p = widget.settings.deviceProfile;
    return Scaffold(
      appBar: AppBar(title: const Text('設置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('手感調參（perDeviceProfile）',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text(
                    '各設備採樣率 60~240Hz 不等，手感參數需按設備微調。'
                    '改完回編輯器即時生效（已畫好的筆也會重算輪廓）。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Text('maxSpeed: ${p.maxSpeed.toStringAsFixed(0)} px/s'),
                  Slider(
                    min: 400,
                    max: 5000,
                    value: p.maxSpeed.clamp(400, 5000),
                    onChanged: (v) => setState(() => p.maxSpeed = v),
                    onChangeEnd: (_) => widget.settings.save(),
                  ),
                  Text('emaWeight: ${p.emaWeight.toStringAsFixed(2)}'),
                  Slider(
                    min: 0.0,
                    max: 0.95,
                    value: p.emaWeight.clamp(0.0, 0.95),
                    onChanged: (v) => setState(() => p.emaWeight = v),
                    onChangeEnd: (_) => widget.settings.save(),
                  ),
                  Text('thinning: ${p.thinning.toStringAsFixed(2)}（壓感對粗細的影響）'),
                  Slider(
                    min: -0.9,
                    max: 0.95,
                    value: p.thinning.clamp(-0.9, 0.95),
                    onChanged: (v) => setState(() => p.thinning = v),
                    onChangeEnd: (_) => widget.settings.save(),
                  ),
                  Text('streamline: ${p.streamline.toStringAsFixed(2)}（線條平滑）'),
                  Slider(
                    min: 0.0,
                    max: 1.0,
                    value: p.streamline.clamp(0.0, 1.0),
                    onChanged: (v) => setState(() => p.streamline = v),
                    onChangeEnd: (_) => widget.settings.save(),
                  ),
                  FilledButton(
                    onPressed: () async {
                      await widget.settings.save();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已保存設備參數')),
                        );
                      }
                    },
                    child: const Text('保存設備參數'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: const Text('手掌誤觸拒絕 (palmRejection)'),
              subtitle: const Text(
                  '開啟後觸控筆書寫、一根手指改為滑動畫布（Apple Pencil / S Pen 用戶需要；圈選工具內手指照常用）'),
              value: widget.settings.palmRejection,
              onChanged: (v) async {
                setState(() => widget.settings.palmRejection = v);
                await widget.settings.save();
              },
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '同步預留：本地 notes/ 為唯一真相來源。未來接入 MEGA（FFI 官方 C++ SDK），'
                '策略 Last-Write-Wins；雙端同改時用 history/ 快照按筆畫時間戳合併。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
