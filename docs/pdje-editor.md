# PDJE エディタ / 譜面DB モデル（調査メモ）

PDJE には**オフラインで譜面を作り、DBに保存する**本格的なオーサリング基盤がある。
「サンプルに事前に譜面を作って保存できるか？」への回答は **できる**。ただし採否は
**保存側ではなく読み戻し側**で決まる。ここではその全体像と、我々の判断根拠を記録する。
関連決定: [decisions.md](decisions.md) D-3 / D-4 / D-5。

出典: 公式ドキュメント
[Editor_Workflows](https://rliop913.github.io/Project-DJ-Engine-Docs/Editor_Workflows.html) /
[Editor_Format](https://rliop913.github.io/Project-DJ-Engine-Docs/Editor_Format.html)、
同梱 `addons/Project_DJ_Godot/ProjectDJGodot_Agent_Docs/`（core / judge）、
`addons/Project_DJ_Godot/examples/GAME_TEMPLATE.tscn`。

## 概念マップ

| PDJE概念 | 実体 | 我々にとっての意味 |
| --- | --- | --- |
| **musdata** | 音源1件の登録: title / composer / path / bpm / **firstBeat** | サンプル登録。`firstBeat` = 最初の拍が始まる **PCMフレーム位置** = ビートグリッドの起点 |
| **trackdata** | 1つの「Track」= `MixBinary` + `NoteBinary` + 参照音源リスト | **譜面(Note)とミックス(Mix)を束ねた1アレンジ**。いわゆる Chart + Mixset |
| **NoteArgs** | 譜面ノート行 | 拍グリッドの本物の譜面。レーンも長押しも表現可（下記） |
| **MixArgs** | 楽曲時間軸上のFX/自動化 + LOAD/UNLOAD/BPM_CONTROL | **動的な曲そのもの**を宣言的に記述する自動化タイムライン |
| **MusicArgs** | BPM タイムライン / 音源メタ | 曲のテンポ変化 |
| 編集履歴 | Undo/Redo/Go/GetDiff/GetLogWithJSONGraph | エディタプロジェクトは **git リポジトリ**（InitEditor に author名/メール） |

ルートDBは litedb（SQLite系）。バイナリは Cap'n Proto。JSON が編集用の表現。

### NoteArgs のフィールド（借用価値あり）

```
note_type(自由文字, 例 "TAP") / note_detail(uint16) / first / second / third /
beat / sub_beat / separate            # 開始位置（beat + sub_beat/separate）
e_beat / e_subBeat / e_separate       # 終了位置 → 埋めるとロングノート
rail_id(uint64)                       # レーン
```

- 時間モデルは `beat + sub_beat/separate`（16分なら separate=4 等）。**BPM 非依存**で、
  我々の `data/charts/*.json` の `step` と同じ発想 → [decisions.md](decisions.md) Q-2。
- `note_type` は開いたテキストで、**`"BPM"` だけ予約**（テンポ断片として扱われ判定対象外）。
- `firstBeat` は Beat This のダウンビート出力で埋められる（検出とグリッドの接点）。

## Godot ラッパーで叩ける範囲（＝保存は可能）

`examples/GAME_TEMPLATE.tscn` が実際にこの流れで譜面をDBへ書いている:

```
InitEditor → GetEditor → ConfigNewMusic(サンプル登録)
→ PDJE_EDITOR_ARG.InitNoteArg(type, detail, f, s, t, beat, sub, sep, e…, rail_id) → AddLine()
→ (必要なら InitMixArg / InitMusicArg も同様に AddLine)
→ render(trackTitle)   # lint + 検証
→ pushTrackToRootDB(trackTitle) / pushToRootDB(title, composer)
```

つまり **「サンプルに事前に譜面を作り、DBへ保存」は正面から用意されており、GDScript から可能。**

## 読み戻しのギャップ（＝採否を決める本質）

保存できても、**保存した譜面を実ゲームでどう取り出すか**が問題。

- **文書化された消費者は Judge モジュールだけ。** `SetNotes(core, track_title)` で Track の
  ノートを Judge に読み込ませ、rail_id ↔ デバイス/MIDI を対応付けて判定シグナルを出す。
  = 正規ルートは **PDJE の Judge + Input 採用**（Windows優先・レール/デバイスマッピング・
  毎フレーム入力ポンプ）。
- **GDScript にノートを配列で読み戻す口は未文書。** ラッパーに `getAll()` はあるが
  「Godot 側の戻り形は未文書・空/既定になり得る」と明記（core ドキュメント）。
  → 既存の GDScript 判定へ流し込む経路は **未文書・要検証**。

**帰結: 保存はできるが、今の GDScript 判定でそれを鳴らす素直な道はない。** これが D-3 の
本当の理由（「保存できないから」ではなく「読み戻し/Judge が重いから」）。

## MixArgs（自動化エンジン）と ライブFX の区別 — 重要

- **MixArgs = 事前オーサリングした自動化タイムライン**（拍時間軸で「いつどのループを
  LOAD/UNLOAD し、どのFXカーブをかけるか」をDBに保存して再生する仕組み）。**これは今は採らない**
  → その自動化・シーケンス層は **自前実装**（[decisions.md](decisions.md) D-5）。
- **ただし FX 本体（18種DSP）とレイヤーON/OFF の“部品”は音声側（D-4）から使える。**
  `getFXHandle()`/`SetFXArg()` と `MusPanel.SetMusic()` は MixArgs を通さず**ライブに叩ける**。
- したがって失うのは「宣言的に前もって書いた自動化を再生してくれるエンジン」だけ。
  我々は代わりに **GDScript から毎フレーム命令的に FX/レイヤーを叩く**（コンボや取得スキルに
  反応してリアルタイムに動かす今の設計と相性が良い）。

## いつ PDJE エディタ採用を再検討するか

以下のどちらかを決めたときだけ、Note保存＋DB採用の旨みが一気に出る（譜面＋曲アレンジ＋FXが
1つの拍タイムラインと1つのバージョン管理DBに乗るため）:

1. **PDJE の Judge を採用する**と決めたとき（Windows限定OK・µs精度が欲しい）。
2. **MixArgs の自動化エンジン**を動的な曲の実装基盤に据えると決めたとき。

それまでは譜面オーサリング＆判定は自前 JSON + GDScript のまま（D-3 維持）、
ビートグリッド形式だけ借用する。
