# 相容性與過渡補丁清單

本文件記錄所有「為了相容舊資料/舊 bug 遺留」而存在的代碼。每一條都標註
**位置（按符號名，行號會漂移）**、**為什麼存在**、**拔除條件**。
定期回頭看這份文件，條件達成的就可以刪。

---

## 1. 孤兒 sidecar 自癒掃描（過渡補丁）

- **位置**：`lib/storage/note_repository.dart`
  - `_orphanIndex` / `_scanOrphanIndex` / `_adoptOrphan`
  - 四個呼叫點：`loadBackground`、`loadOriginalPdf`、`loadImage`、`loadThumbnail`
  - 輔助：`_safeKey`
- **為什麼存在**：舊版 `save()` 發現路徑變化（跨日/改標題/搬資料夾）時只搬
  json、不搬 sidecar，造成 `_bg*.png` / `_orig.pdf` / `_img*.png` / 縮圖
  全部失聯（PDF 底圖永久不顯示的根因，commit `f148101` 修）。
  P0-1（`_moveSidecars`）只保證**之後**不再產生孤兒；**已經中招的舊筆記**
  需要打開時掃描找回。
- **拔除條件**（兩者都達成）：
  1. P0-1 已上線（新 save 不再產生孤兒）——已達成；
  2. 所有既有筆記都開過一遍（自癒不再命中，`debugPrint`
     `note_repository: adopt orphan ...` 全庫零輸出）。
- **關聯測試**：`test/note_repository_test.dart`「孤兒 sidecar 自癒…」
  「孤兒縮圖自癒…」。**拔除時把這兩條測試一起刪**（它們測的就是補丁本身；
  P0-1 的搬移測試「改標題保存…」「搬資料夾…」要保留）。

## 2. 舊版 PageBg 無 `src` 的原頁碼解析（`_bgSrc` key 兜底）

- **位置**：`lib/ui/editor_page.dart` — `_bgSrc()`
- **為什麼存在**：舊版 `PageBg` 沒有 `src` 欄位（原 PDF 頁碼），底圖 key
  形如 `p0`、`p1`……`_bgSrc` 按 `^p(\d+)$` 從 key 還原原頁碼；
  完全無 key 的更老版本直接用顯示下標。渲染（fill/升級）與頁面管理
  副標題都走它。
- **拔除條件**：一次性遷移把所有無 `src` 的 `PageBg` 補上 `src`（或確認
  資料庫中已無此形態）後，簡化為直接讀 `bg.src`。
- **關聯測試**：`test/pdf_bg_test.dart`「頁面管理副標題：舊版無 src 走
  `_bgSrc` 兜底…」。

## 3. `_bgKey` 的 `p{i}` 兜底

- **位置**：`lib/ui/editor_page.dart` — `_bgKey()`
- **為什麼存在**：`PageBg.key` 為空串的舊版筆記，底圖檔名用 `p{i}` 兜底
  （與 #2 同一批資料）。
- **拔除條件**：同 #2（遷移補 key 後刪除）。

## 4. 舊文件缺欄位的 `fromJson` 預設值

- **位置**：`lib/models/note.dart` — `Stroke.fromJson`（無 `type` → 手寫筆）、
  `Note.fromJson`（無 `images` → 空列表、無 `folder` → 根目錄、無 `page`
  → `pageId = null` 無限畫布）
- **為什麼存在**：向前相容——舊格式 json 永遠存在於使用者裝置上，
  沒有版本遷移機制。
- **拔除條件**：引入 `Note.version` 一次性升級流程（load 時補寫缺失欄位
  並升版）後，舊版分支可刪。**在那之前這是永久相容層，不要動。**

## 5. PDF 虛擬尾頁物化（`_materializeExtraPages`）

- **位置**：`lib/ui/editor_page.dart` — `_materializeExtraPages()`；
  load 路徑與 `_exportPdf` 均會呼叫
- **為什麼存在**：舊版把「末尾虛擬空白頁」記在 `extraPages`（紙筆記）或
  直接不落盤（PDF），重開時要補回真頁。頁數翻倍 bug（`e39e587`）就是
  額度算錯＋物化放大造成的。
- **拔除條件**：所有舊筆記都開過一次（`extraPages` 已物化落盤）且新版本
  不再寫入 `extraPages`（PDF 路徑）後可簡化。**紙筆記的 `extraPages`
  機制是現役設計，不在刪除範圍。**

## 6. 歷史目錄按 `_$id` 後綴掃描

- **位置**：`lib/storage/note_repository.dart` — `listHistory()` /
  `listHistoryFiles()`（註解「歷史目錄 key 可能來自舊文件名」）
- **為什麼存在**：歷史目錄以**檔名**為 key，而檔名含日期+標題（每次
  save 都可能變），同一筆記的快照散在多個 key 目錄下，只能按 id 掃。
- **拔除條件**：這是檔名設計（#7）的連帶症狀。若未來檔名改為純
  `{id}.json`，歷史 key 穩定後可改為單目錄直取。

## 7. （設計債，非補丁）檔名 = `{日期}_{標題}_{id}.json`

- **位置**：`lib/models/note.dart` — `fileName()`
- **為什麼列在這裡**：它是 #1、#6 的根。P0-1（`_moveSidecars`）已把
  危害兜住，但每次跨日/改標題仍觸發全量改名+搬 sidecar。
- **拔除條件**：大手術——檔名改 `{id}.json` ＋ 一次性遷移（搬檔+改
  history key）。做完後 #1 的 P0-1 與 #6 都可簡化。

---

## 永久性兜底（不是過渡，別列進刪除清單）

- `share_common`：分享 MIME 亂填時按副檔名猜——外部 App 行為不可控，永久。
- `pdf_vector`：缺字形逐字用系統字體兜底——字體環境不可控，永久。
- `decodePng` / 各 load 路徑的 `catch → null`：失敗返回空值不炸 UI；
  但**新代碼不要再靜默吞**，至少 `debugPrint` 一句。
