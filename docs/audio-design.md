# 音源設計

[vision.md](vision.md) の柱1（ジャンル変化）と柱2（リアルタイムFX）を支える土台。

## レイヤー（ステム）モデル【提案】

曲を「1本の完成品」ではなく **複数のループ音源の重ね合わせ** として持つ。

```
Atmosphere  ░░░░░░░░  ← スキルで解禁されると鳴り始める
Lead        ████████
Chords      ████████
Bass        ████████
Drums       ████████  ← 最初から鳴っている土台
            ─────────────> 時間（全レイヤー同じ長さでループ）
```

- **スロット** = 曲の役割（Drums / Bass / Chords / Lead / Atmosphere）
- **バリアント** = そのスロットのジャンル別音源（Drums-House / Drums-DnB / …）
- スキル取得 = スロットにバリアントを差す or 有効化する
- 全スロットが埋まる = **1曲完成 → プレステージ解禁**

排他スキルは「1スロットにつきバリアントは1つだけ」という制約として自然に表現できる。

### この設計の必須条件

**全バリアントが同じ BPM・同じ小節数でループすること。**
これを守らないとレイヤーの差し替えが破綻する。音源を用意する際の最重要仕様。

【提案】まずは **BPM 128 / 4小節ループ / 同一キー** に固定して作り始める。
キーまで揃えると Chords/Lead を自由に組み替えても不協和にならない。

## PDJE でどう実現するか

PDJE（`addons/Project_DJ_Godot/`）は DJ エンジンなので、この用途にほぼ理想的な API を持つ。
**重要: 音声（Core/MusPanel/FX）だけ採用し、判定（Judge）と譜面DBは採用しない、という分離ができる。**

### レイヤー ON/OFF

`MusPanelWrapper` は複数音源を同時ロードし、個別に ON/OFF できる。

```gdscript
# FULL_MANUAL_RENDER or HYBRID_RENDER が必要
var muspanel := player.GetMusicControlPanel()
muspanel.LoadMusic("drums_house", "composer", 128.0)
muspanel.LoadMusic("bass_house",  "composer", 128.0)

muspanel.SetMusic("drums_house", true)   # レイヤーON
muspanel.SetMusic("bass_house", false)   # レイヤーOFF
muspanel.ChangeBpm("drums_house", 140.0, 128.0)  # タイムストレッチ
```

`ChangeBpm()` があるので、BPM の違うバリアントも後から吸収できる（が、
最初から揃えておくほうが音質・実装ともに楽）。

### リアルタイム FX（柱2）

音源ごとに FX ハンドルが取れ、パラメータをフレーム単位で書き換えられる。

```gdscript
var fx := muspanel.getFXHandle("drums_house")
fx.FX_ON_OFF(EnumWrapper.PDJE_FX_LIST.FILTER, true)
var args := fx.GetArgSetter()
args.SetFXArg(EnumWrapper.PDJE_FX_LIST.FILTER, "HLswitch", 0)      # 0=highpass
args.SetFXArg(EnumWrapper.PDJE_FX_LIST.FILTER, "Filterfreq", 800.0)
```

利用可能な FX（18種）:
`FILTER` `EQ` `DISTORTION` `CONTROL` `VOL` `LOAD` `UNLOAD` `BPM_CONTROL`
`ECHO` `OSC_FILTER` `FLANGER` `PHASER` `TRANCE` `PANNER` `BATTLE_DJ`
`ROLL` `COMPRESSOR` `ROBOT`

【提案】柱2 のマッピング例:

| 入力 | FX | 効果 |
| --- | --- | --- |
| コンボが伸びる | `FILTER` Filterfreq を上げる | 曇った音 → 抜けの良い音 |
| ミスする | `DISTORTION` を一瞬 | 音が歪んで失敗が聴覚でわかる |
| 高精度維持 | `ECHO` / `ROLL` wet 上げ | 演出的な華やかさ |
| スキル取得 | `COMPRESSOR` / `EQ` 常時 | 恒久的に音圧・帯域が改善 |

> **【要検証】** FX の引数キー（`"Filterfreq"` 等）は**大文字小文字を区別**する。
> 正確なキー一覧は https://rliop913.github.io/Project-DJ-Engine-Docs/FX_ARGS.html
> を実装時に必ず参照すること。`GetFXArgKeys(fx)` で実行時に列挙もできる。

### ビート検出（自動譜面化の鍵）

PDJE は Beat This モデル（ONNX）を同梱しており、**任意の音源からビート／ダウンビートの
タイムスタンプ（秒）を抽出できる**。

```gdscript
var ai := PDJE_AI.new()
var detector := ai.CreateBeatThisDetector(
    "res://addons/Project_DJ_Godot/onnx_models/beat_this_model_final0.onnx")
var result := detector.DetectPCM(interleaved_pcm, channels, sample_rate)
# result.beats     : PackedFloat64Array（秒）
# result.downbeats : PackedFloat64Array（秒）
```

これが効くのは **音源を自前で用意しない場合**（AI生成音源など）。
手元にないループでもビートグリッドを機械的に取れるので、譜面の自動生成が現実的になる。

> **【要検証】** エクスポート時は `.onnx` モデルと ONNX Runtime のDLL
> （`onnxruntime.dll` / `onnxruntime_providers_shared.dll`）を同梱する必要がある。

## 音源をどう調達するか【未決定】

ユーザー曰く「まだ決めていない。ループ音源ファイルを必要なだけ渡すことはできる。
Gemini API の音楽生成が使えたら一番嬉しい」。

3案あり、**排他ではなく組み合わせられる**。

### 案A: ループ音源ファイルを手で用意する

| | |
| --- | --- |
| 長所 | 決定的・オフライン動作・譜面を作り込める・音質を保証できる・法的に明快 |
| 短所 | バリアント数だけ音源が必要（5スロット × 4ジャンル = 20ファイル） |
| 向き | **本編／出荷する体験** |

最も確実。柱1・柱2はこれだけで完全に実現できる。

### 案B: Gemini API で実行時に生成（Lyria RealTime 系）

> **【要検証】** Google の音楽生成は Lyria 系モデルとして Gemini API 経由で
> 提供されている（重み付きプロンプトで BPM・密度・ブライトネス等を指定し、
> PCM をストリーミング受信、生成中にプロンプトを差し替えて曲調を変えられる）。
> **ただしモデル名・提供形態・料金・利用規約は変動が激しいため、
> 着手時点で必ず公式ドキュメントを確認すること。** 以下は現時点の想定に基づく評価。

| | |
| --- | --- |
| 長所 | 「スキルの重み → プロンプトの重み」が概念的にほぼ1対1で、柱1と相性が異常に良い |
| 短所 | ネットワーク必須・レイテンシ・課金・**譜面と音がズレる**・再現性がない・生成物の権利/透かし |
| 向き | エンドレス／ジャムモードなどの**サブモード** |

**リズムゲームの中核に置くのは危険。** 譜面はサンプル精度で音と一致している必要があるが、
生成音声は決定的でないため、同じビルドで同じ譜面が保証できない。
ただし上記の Beat This によるビート検出と組み合わせれば
「生成 → ビート抽出 → グリッド上に譜面自動生成」は成立しうる。

### 案C: Gemini を開発時のアセット生成に使う 【提案・本命】

生成AIで**ループ素材を作り、書き出して通常のファイルとして同梱する**。

| | |
| --- | --- |
| 長所 | 案Aの利点（決定的・オフライン・作り込み可）を全部保ちつつ、素材制作コストを下げられる |
| 短所 | 生成物のライセンス確認が必要 |
| 向き | **音源調達の現実解** |

「AI で音楽を作りたい」という欲求と「リズムゲームは決定的でなければならない」という
制約を両立させる。ランタイム依存が一切増えないのが大きい。

**【提案】まず案C（または案A）で出荷ラインを作り、案Bは後からサブモードとして検討する。**

## 譜面設計への影響【重要】

ジャンル変化を入れると、現在の譜面フォーマットが破綻する可能性がある。

現状 `data/charts/demo_chart.json` は **秒単位**:

```json
{ "time": 1.50, "lane": 1 }
```

ジャンルによって BPM が変わる／`ChangeBpm()` でストレッチするなら、
秒指定の譜面はズレる。

**【提案】譜面を拍ベース（beat / sub_beat）に移行する。**

```json
{ "beat": 4, "sub": 2, "lane": 1 }
```

`Conductor.beat_to_seconds()` が既にあるので変換は容易。
BPM 固定で進めるなら急がないが、**ジャンル変化を実装する前には決めておく**こと。
（PDJE の Judge を将来使う場合も、PDJE 側の譜面は拍ベースなので移行は無駄にならない）

## 段階的な進め方【提案】

| 段階 | やること | 依存 |
| --- | --- | --- |
| 0 | ループ1本を `AudioStreamPlayer` で鳴らし、`Conductor` と同期・レイテンシ確認 | なし |
| 1 | PDJE を音声用途で導入（`FULL_MANUAL_RENDER` + MusPanel）、レイヤー ON/OFF | PDJE |
| 2 | スキル → レイヤーのマッピング（柱1） | 段階1 |
| 3 | コンボ/精度 → `SetFXArg()`（柱2） | 段階1 |
| 4 | 譜面を拍ベースへ移行 | ジャンル変化前に |

段階0 は PDJE なしでできるので、**音源が手に入り次第すぐ着手してよい**。
判定ロジックは GDScript のまま据え置き（[decisions.md](decisions.md) 参照）。
