# Ink Notes

Flutter 手寫筆記 App：壓感筆跡、形狀修正、圖層、連續頁面、PDF 向量匯入／匯出。

## 功能

- **筆跡**：速度壓感（EMA＋smoothstep）、`perfect_freehand` 輪廓、筆／螢光／虛線／幾何筆
- **形狀修正**：停頓滿 1s 預覽，直線／矩形／圓吸附（收筆 dwell 判定）
- **橡皮**：按筆畫即刪、像素按段即擦，整次拖抹一次 undo
- **圈選**：套索＋移動／旋轉，出紙部分抬起才裁
- **頁面**：連續頁堆疊、頁面管理（排序／插空白／刪頁，筆跡重映射可撤銷）
- **圖層**：多圖層＋隱藏（不畫、不命中、不匯出）
- **PDF 匯入**：純 Dart 向量渲染（字形描邊＋系統字兜底），無 pdfium；懶加載＋縮放按需提清
- **PDF 匯出**：向量增量保存（壓感 Ink／虛線／幾何／螢光），失敗回退光柵
- **手勢**：雙指縮放／平移／快掃翻頁，雙指點兩下 undo、三下 redo（立刻觸發）
- **防誤觸**：開後僅筆／滑鼠落筆，觸屏改平移，縮放自由，手掌不打斷書寫

## 儲存

- 桌面／移動端：文件儲存（`Documents/MyInkNotes`，每筆記一 JSON 原子寫入＋gzip 歷史＋縮圖／底圖／原 PDF）
- Web：內存儲存（reload 不持久，僅預覽）
- 手感參數可按設備調（設置頁：maxSpeed／emaWeight／thinning／streamline＋保存）

## 開發

```bash
flutter pub get
flutter analyze        # 須零問題（CI 擋）
flutter test           # 全量測試
flutter run -d windows # 桌面
flutter run -d chrome  # Web 預覽
```

## CI（`.github/workflows/ci.yml`）

- `test-windows`：analyze＋全量測試
- `build-windows`：`flutter build windows --release`
- `build-android`：`flutter build apk --release`（無正式 keystore 時 debug key 簽名，可 adb 直裝）
- `build-ios`：`flutter build ios --no-codesign`＋未簽名 IPA（真機需本地重簽或付費帳號走 TestFlight）
- `build-linux`：analyze＋測試＋編譯
