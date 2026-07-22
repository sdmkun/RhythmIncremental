# タスク仕様: Beat This ビート検出 動作確認シーン

> **【実装済み 2026-07-22】** `scenes/tools/beat_check.tscn` / `.gd`。
> 受け入れ条件は下記「実行結果」参照。実測値と確定した手順は
> [`../audio-design.md`](../audio-design.md) の「ビート検出」節と
> [`../decisions.md`](../decisions.md) Q-1 に反映済み。
> 本文中の【要検証】はすべて解消済み（該当箇所に結果を追記した）。

**担当想定: Claude Code（Godot MCP で実装 → 実行テストまで行う）**
このドキュメントは単体で着手できるよう自己完結させてある。着手前に
[`../audio-design.md`](../audio-design.md) の「ビート検出」節と
[`../decisions.md`](../decisions.md) D-4 を確認すること。

---

## ゴール

`res://audio/loops/` のループ WAV を選ぶと、PDJE の Beat This で拍を検出し、
**検出した各ビートのタイミングに合わせて `res://audio/sfx/` の click 音を鳴らす**
動作確認用シーン。曲が再生されている間、click がビート上で鳴ればビート検出が
機能していると確認できる。ゲーム本編には組み込まない、独立した検証ツール。

## 受け入れ条件（すべて Godot MCP で実際に実行して確認する）

1. プロジェクトがパースエラーなく開ける（`--headless` でもよい）。
2. 検出器が生成できる（`CreateBeatThisDetector(...) != null` = モデルがロードできた）。
3. 選んだループに対し `result != null` かつ `result.beats` が非空。
   - コンソールに **ビート数・推定BPM（`60 / 隣接ビート間隔の中央値`）・先頭8個の秒値** を出力。
     これは音が聞けないヘッドレス実行でも検証できる指標。
4. 再生すると click がビート位置で鳴り、画面のメトロノーム表示も同期して光る
   （Windows + 音声ありでの最終確認）。
5. **DetectPCM と DetectMusic の両方**を切り替えて試せる（下記トグル）。両方で
   `beats` が返ることを確認する。
6. 失敗系（モデル null / result null / WAV が QOA インポート等）で
   クラッシュせず、原因が分かるログを出す。

---

## 実装場所・規約

- 新規シーン: `scenes/tools/beat_check.tscn`（ルート `Control` + スクリプトのみ、
  UI は `_ready()` で手続き生成）。既存の thin-scene 規約に合わせる
  （[`../../CLAUDE.md`](../../CLAUDE.md) 参照）。
- メインメニューに「Beat Check」ボタンを足して遷移できるようにする（任意だが推奨）。
- Godot 4.7.1 / 型付き GDScript。`Conductor.output_latency` を click スケジュールの
  オフセットに再利用する。
- **Windows 前提**（PDJE は Windows の GDExtension）。他 OS ではボタンを無効化して
  「Windows のみ」と表示する程度でよい。

## 使う PDJE API（同梱ドキュメントで確認済み）

モデルパス（実在を確認済み）:
`res://addons/Project_DJ_Godot/onnx_models/beat_this_model_final0.onnx`

```gdscript
var ai := PDJE_AI.new()
var detector := ai.CreateBeatThisDetector(MODEL_PATH)   # null なら失敗
# result.beats / result.downbeats は PackedFloat64Array（秒）
```

- **DetectPCM**: `detector.DetectPCM(pcm: PackedFloat32Array, channel_count: int, sample_rate: int)`
  - `pcm` は**インターリーブ**。長さは `channel_count` で割り切れること（フレーム整列を検証される）。
  - 内部でモノにダウンミックスしてから推論する。
- **DetectMusic**: `detector.DetectMusic(core_api: PDJE_Wrapper, title, composer, bpm)`
  - 初期化済みの `PDJE_Wrapper` に音源が登録されている必要がある。

出典: `addons/Project_DJ_Godot/ProjectDJGodot_Agent_Docs/harness/util/README.md`（Beat This Examples 節）。

---

## ルート1: DetectPCM（登録不要・まずこちらで疎通）

PDJE の DB 登録が要らず最軽量。**WAV をディスクから自前パースして float PCM を作る**
のが最も確実（Godot のインポート形式に依存しないため）。

### なぜ自前パースか【重要な落とし穴】

Godot 4.4+ は WAV を既定で **QOA 圧縮**としてインポートするため、
`AudioStreamWAV.data` が生 PCM とは限らない。回避策は2つ:

- **(推奨)** `FileAccess.open("res://audio/loops/x.wav", READ)` で読み、RIFF/WAVE の
  `fmt ` と `data` チャンクを自前で解釈して float PCM に変換する。sample_rate と
  channel_count もヘッダから正確に取れる。PCM 16/24/32-bit と IEEE float(fmt=3) に対応させる。
- **(代替)** インポート設定で該当 WAV の **Compression = Disabled(PCM)** にしてから
  `AudioStreamWAV` の `data` / `format` / `stereo` / `mix_rate` を使う。

`float [-1.0, 1.0]` のインターリーブ `PackedFloat32Array` を作り、
`DetectPCM(pcm, channels, sample_rate)` に渡す。

### 疎通確認

`result.beats` が非空か、推定BPMがループの体感テンポと近いかをログで確認。

---

## ルート2: DetectMusic（PDJE 登録経由）

`config_and_play.gd` の初期化列に倣う。将来の MusPanel/FX 統合と地続き。

```gdscript
var engine := PDJE_Wrapper.new()
engine.InitEngine(DB_PATH)                 # 下記の注意参照
if engine.SearchMusic(title, composer).is_empty():
    engine.InitEditor("name", "none", EDITOR_PATH)
    var editor = engine.GetEditor()
    editor.ConfigNewMusic(title, composer, "res://audio/loops/x.wav")
    var arg := PDJE_EDITOR_ARG.new()
    arg.InitMusicArg(title, str(bpm), 0, 0, 4)
    editor.AddLine(arg)
    editor.render("sample_track")
    editor.pushToRootDB(title, composer)
var result := detector.DetectMusic(engine, title, composer, bpm)
```

- ~~**【要検証】** DetectMusic に最低限必要なステップ~~ → **確定: `InitPlayer` は不要。**
  `InitEngine` → `InitEditor` → `ConfigNewMusic` → `InitMusicArg`/`AddLine` →
  `render`（`"RENDER COMPLETE"`）→ `pushToRootDB` の登録だけで `DetectMusic` が通る。
  `ConfigNewMusic` は `res://` パスをそのまま受け付ける（絶対パス化は不要だった）。
  `beat_check.gd::_detect_music()` は A(登録のみ) → B(+InitPlayer) → C(絶対パス) の順に
  試して成功した戦略をログに出す作りになっており、実行では毎回 A で成功している。
- **【落とし穴】** サンプルは `InitEngine("res://rootdb")` のように **res:// に DB を
  書いている**が、エクスポート後の `res://` は読み取り専用。**この検証ツールでは
  `user://pdje/rootdb` / `user://pdje/editor` を使うこと。** DetectPCM ルートには DB は不要。
- **【判明】** PDJE は `<cwd>/logs/pdjeLog.txt` にログを書く（プロジェクトルートに
  `logs/` ができる）。`.gitignore` 済み。
- `bpm` はループが分かっていれば実値、不明なら `-1.0` や `120` を渡して挙動を見る。
  → ファイル名から BPM を拾う実装にした（`_bpm_from_filename()`）。検出結果との比較に使う。

---

## click 再生（両ルート共通）

1. 検出した `beats`（秒, `PackedFloat64Array`）を保持。
2. ループ WAV を `AudioStreamPlayer` で再生（インポートで Loop=Forward、または
   `AudioStreamWAV.loop_mode` を設定）。再生位置は既存 `Conductor` と同じ方式で追う
   （`get_playback_position() + AudioServer.get_time_since_last_mix() - output_latency`）。
3. 再生位置が次のビート秒を跨いだら click を鳴らす（ビート配列に対しインデックスを進める）。
   - click は**同時多重に耐えるよう `AudioStreamPlayer` を数本プール**（8本程度）して
     ラウンドロビンで鳴らす。1本だと連続ビートで切れる。
   - ループが短く曲を繰り返す場合、ビート配列もループ長で mod して各周回で再生する。
4. 画面にメトロノームのフラッシュ（`ColorRect` を一瞬光らせる）と、
   検出ビート数・推定BPM・現在ビート番号を表示。

> 精度メモ: 検証用途なので毎フレーム閾値トリガで十分。より厳密に合わせたいなら
> `AudioServer` の時刻基準で先読みスケジュールに置き換えられる（本タスクでは任意）。

---

## UI（手続き生成）

- `res://audio/loops/` を `DirAccess` で走査して `.wav` を一覧化 → 選択 UI（`OptionButton` 等）。
- ボタン: **Detect**（選択ループを検出）/ **Play・Stop** / **API 切替（PCM ⇄ Music）**。
- click 音は `res://audio/sfx/` の WAV を1つ拾う（複数あれば先頭、または選択可）。
- ラベル: モデルロード可否 / result 可否 / ビート数 / 推定BPM / 先頭8ビートの秒値。

## 検証手順（Claude Code が実行まで行う）

1. パースチェック（`--headless`）→ エラーゼロ。
2. シーンを実行し、DetectPCM で選択ループを検出 → ビート数・推定BPM をログ確認
   （音なしでも判定可能な受け入れ条件3を満たす）。
3. API を DetectMusic に切替 → 同様に `beats` が返ることを確認。最小初期化列を確定して
   本ドキュメントの【要検証】を潰し、判明した手順を追記する。
4. 音声ありで click とメトロノームがビートに乗るのを確認。
5. 短いループでダウンビート推定がぶれる場合の挙動をメモ（`../audio-design.md` の注意の裏取り）。

## 完了後にやること

- ~~判明した DetectMusic の最小手順・PCM 変換の要点・短尺ループの精度を
  [`../audio-design.md`](../audio-design.md) に反映。~~ → 反映済み
- ~~検出が実用になるか（自作ループでは既知BPMからグリッド算出のほうが正確か）の所感を
  [`../decisions.md`](../decisions.md) の Q-1 周辺に追記。~~ → 追記済み

---

## 実行結果【2026-07-22】

環境: Godot 4.7.1 / Windows 11 / PDJE 0.9.2（wrapper 0.9.0）。

| # | 受け入れ条件 | 結果 |
| --- | --- | --- |
| 1 | パースエラーなく開ける | ✅ `--headless` 実行でエラーゼロ |
| 2 | 検出器が生成できる | ✅ `CreateBeatThisDetector OK` |
| 3 | `result != null` かつ `beats` 非空 + ログ出力 | ✅ 正常な WAV 6/6 で成功。ビート数・推定BPM・先頭8ビートを出力 |
| 4 | click とメトロノームがビートに乗る | ✅ ドリフト +0〜6 ms（`--autoplay` で全クリック実測）。**耳での最終確認はユーザー待ち** |
| 5 | DetectPCM / DetectMusic 両方で `beats` が返る | ✅ 両方成功。結果は完全一致 |
| 6 | 失敗系でクラッシュせず原因が分かる | ✅ 壊れた WAV を置いて実測 → `WAV parse failed: not a RIFF file` を出して継続、終了コード1 |

**精度についての所感は条件を満たすかとは別問題**（→ [`../decisions.md`](../decisions.md) Q-1 追記）。
API は完全に動くが、既知BPMのループでは計算でグリッドを出すほうが正確。

### 実行方法

```bash
# ヘッドレス一括検証（全ループを DetectPCM → 先頭ループを DetectMusic → 終了）
Godot_v4.7.1-stable_win64_console.exe --headless --path . res://scenes/tools/beat_check.tscn

# 音声ありでクリックのズレを実測（ドラムループを2周再生してログ出力 → 終了）
Godot_v4.7.1-stable_win64_console.exe --path . res://scenes/tools/beat_check.tscn -- --autoplay

# 手動（メインメニュー →「Beat Check (tool)」ボタン）
```
