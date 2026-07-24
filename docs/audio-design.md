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

### レイヤー ON/OFF 【2026-07-24 実装・稼働中】

`MusPanelWrapper` は複数音源を同時ロードし、個別に ON/OFF できる。

**実装済み**: `data/songs/pdje_song.gd`（`class_name PdjeSong`）が
メインの音ゲーパートの再生を担当している。検証は
`scenes/tools/pdje_audio_check.tscn`（`-- --auto`）。

確定した最小の再生手順（すべて実行して確認済み）:

```gdscript
engine.InitEngine("user://pdje/rootdb")                  # -> true
# 各音源を1回だけ登録（下記【落とし穴】参照）
engine.InitPlayer(PDJE_Wrapper.FULL_MANUAL_RENDER, "void", 48)   # -> true
var player := engine.GetPlayer(); player.Activate()      # -> true
var panel := player.GetMusicControlPanel()               # null でない
panel.LoadMusic(title, composer, source_bpm)             # -> 1 が成功
panel.ChangeBpm(title, 125.0, 120.0)                     # -> true（後述）
panel.SetMusic(title, true/false)                        # -> true。リアルタイムに切替可
```

> **【落とし穴・重要】1エンジンにつきエディタは1つで、行が残る。**
> 2つ目の音源を同じエディタプロジェクトに通すと `render()` が内部で失敗する:
> ```
> failed to convert bpm to double. from editorObject render.
> invalid stod argument
> ```
> しかも **`render()` の戻り値は "RENDER COMPLETE" のまま**なので気づけない。
> 症状は後段の `LoadMusic()` が **`-2`** を返し、その音源だけ鳴らない。
> 同梱サンプルは音源1個しか登録しないのでこの問題を踏まない。
> → **音源ごとに別のエディタプロジェクトパスを使う**
> （`user://pdje/editor/<title>`）。これで解決した。

> **【落とし穴】タイトルは rootdb 全体で一意。** composer が違っても衝突する。
> `scenes/tools/` の検証ツールが同じ .wav を別 composer で登録していると
> ゲーム側の `LoadMusic()` が `-2` を返す。`PdjeSong` は `ri_` プレフィクスで
> 名前空間を分けている。

> **【判明】`GetConsumedFrames()` は String を返す**（int ではない）。
> `float(str(...))` で受けること。値は仕様通り **/48000 で秒**。

### 時計としての PDJE 【精度実測】

`GetConsumedFrames()/48000` は壁時計に対して **比 1.000（ドリフトなし）**、
起動オフセット約 +0.11 秒の定数のみ。`Conductor.play_external()` でこれを
クロック源にしたところ、ループ境界の実測は:

| 周 | 実測 t | 期待値 | ずれ |
| ---: | ---: | ---: | ---: |
| 2 | 15.360 | 15.360 | **0 ms** |
| 3 | 30.720 | 30.720 | **0 ms** |

`AudioStreamPlayer` 経由（`get_playback_position()`）では 4〜12 ms ずれていたので、
**PDJE のフレームカウンタのほうが明確に正確**。

> **【落とし穴】`LoadMusic()` した時点で曲は再生可能な状態にあり、
> `SetMusic(title,true)` した瞬間から鳴り始める。**
> 登録とロードには 0.9 秒前後かかるので、セットアップ中に ON にしておくと
> **その間に2拍ぶん実際に音が漏れ**、クロック確定時の巻き戻しで途中から
> 頭に戻る。結果、1周目の1拍目と2拍目の間隔が詰まって聞こえる。
> → **クロックが確定するまで全レイヤーを OFF のままにする**
> （`PdjeSong` は意図だけ `_wanted` に記録し、確定時に初めて `SetMusic` する）。
> なお `ChangeBpm()` は **OFF のままでも通る**ので、そのために ON にする必要はない。

> クロックのゼロ点は `start()` の最後ではなく **`position()` の初回呼び出しで確定**させ、
> 同時に全レイヤーを `CueMusic(title,"0")` で巻き戻し、その同じ瞬間に ON にする。
> こうすると曲の1サンプル目と譜面の t=0 が一致する。
>
> なお `Conductor.output_latency`（= `AudioServer.get_output_latency()`）は
> **外部クロック時には適用しない**。あれは Godot 自身のオーディオデバイスの話で、
> PDJE の出力経路とは無関係だから。レイテンシ補正は外部クロック側の責任
> （`PdjeSong` が下記のプリバッファ分を引く）。

### 【重要】GetConsumedFrames は音より 0.111 秒先行している

**`GetConsumedFrames()` が数えているのは「エンジンが生成済みのフレーム」で、
スピーカーから出た音ではない。** 実測すると壁時計より **常に 5328 フレーム
（= 0.111 秒）多い**（23秒間・複数回の実行で一定）。

125 BPM では **1拍(0.48秒)の 23%**。補正しないと次の2つが同時に起きる:

1. **譜面が音より 0.111 秒早い。** ノートが音より先に判定ラインに来る。
2. **ループが早く切れる。** ループ点で `CueMusic(title,"0")` を送ると、
   その時点で聞こえているのはまだ 0.111 秒手前なので、
   **最後の拍の直後で次の周が始まってしまう。**（実際にこの症状が出た）

対処:

- `PdjeSong.ENGINE_PREBUFFER_FRAMES = 5328` を `position()` から引く。
  自動計測はしない — `Activate()` から初回フレームまでの間、登録処理や
  `ChangeBpm()` がブロックするのでカウンタが線形に進まず、計測値が安定しない。
  `InitPlayer()` に渡すフレームバッファサイズ由来の固定値なので定数でよい。
- **`MusPanel` はループしない。** 曲は1回鳴って終わり、そのまま無音になる
  （実機で確認。2周目以降まったく音が出ない）。
  したがってループ点で **自分で `CueMusic(title,"0")` を送る必要がある**
  （`PdjeSong.MANUAL_LOOP = true`）。

> **【重要】cue は「聞こえている位置」で送ること。生カウンタで送ってはいけない。**
> `CueMusic` はプリバッファの後ろに積まれるのではなく、**いまスピーカーから
> 出ている音をつかんで巻き戻す**。したがって生カウンタ基準で送ると
> **プリバッファ分まるごと（0.111秒 = 125BPMで1拍の23%）早すぎ**、
> 毎周ループ末尾を削る。これが「次のループが早く始まる／ドタつく」の正体。
>
> 実測で確認した経緯:
> - 音源のデコード長は正しい（キック 15.36秒、ベース 16.0秒）。再生レートの問題ではない。
> - `CueMusic` の実行コストは 0.0 ms。処理落ちでもない。
> - キックとベースは2周目以降も互いに同期している = 両方が同じだけ切られている
>   = cue の位置がコンテンツ終端より手前、と切り分けられた。
>
> 微調整は `PdjeSong.CUE_TRIM_FRAMES`（48フレーム = 1ms、負値も可）。
> まだ早いなら上げる、継ぎ目に隙間が空くなら下げる。

> **【残る制約】cue はフレーム境界でしか送れない。** ずれた分はそのまま聞こえる
> （遅ければ無音の隙間、早ければ末尾が切れる）。
> 「境界を超えた最初のフレーム」ではなく **「境界に最も近いフレーム」** で送ることで
> 最悪値を半フレーム（60fps で約8ms）に半減させている。誤差は毎周ループ長の
> 絶対値に対して測るので**累積しない**。
> 実測のずれは **0〜10 ms**（`GetConsumedFrames()` 自体が 10 ms 刻みで更新されるので
> これが下限）。

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

**`ChangeBpm()` は実際に動く【2026-07-24 確認】。**
`SSTN_120`（120 BPM のベースループ）を 125 BPM の曲に載せるのに使っており、
`ChangeBpm(title, 125.0, 120.0) -> true`。**リサンプリングではなくタイムストレッチ**
なので音程は変わらない（リサンプリングだと +0.71 半音ずれ、キーのあるベースは破綻する）。

呼ぶタイミングは `LoadMusic()` の直後でよい（音源が OFF の状態でも通る）。
一度これを自前 WSOLA で実装しかけたが、**PDJE が持っている機能なので不要**。
オフラインの合成が要るのはワンショットからループを作る場合だけ
（`data/audio/audio_bake.gd`: キックを拍上に並べて4つ打ちループを作る用途）。

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

#### 実測結果【2026-07-22 検証済み】

検証シーン `scenes/tools/beat_check.tscn`（仕様: [tasks/beatthis-check.md](tasks/beatthis-check.md)）で
`audio/loops/` の6ループを実行。環境は Godot 4.7.1 / Windows / PDJE 0.9.2（wrapper 0.9.0）。
再現コマンド:

```
Godot_v4.7.1-stable_win64_console.exe --headless --path . res://scenes/tools/beat_check.tscn
```

`CreateBeatThisDetector()` は同梱 `.onnx` の `res://` パスでそのまま通り、
**DetectPCM / DetectMusic とも `result != null` かつ `beats` 非空**（正常な WAV では 6/6 成功）。
API としては完全に動く。**問題は精度のほう。**

| ループ | 長さ | 検出ビート数 | 推定BPM | ファイル名のBPM |
| --- | ---: | ---: | ---: | ---: |
| FL_BJ_174_Synth_Pad_Sonic_Gm | 11.0s | **1** | — | 174 |
| SS_XLLRB_150_vocal_adlib_..._chop | 12.8s | 37 | 272.73 | 150 |
| TSP_ENEIV2_175_kit_throwback_drum_E | 21.9s | 45 | 171.43 | 175 |
| TSP_HLZ_174_drum_grace_shaker | 5.5s | 17 | 176.47 | 174 |
| TSP_QUARTZ_174_drum_stalk_sequence_full | 2.8s | 5 | 120.00 | 174 |
| shs_ins_180_kit_songstarter_loop_Rest_Fm | 21.3s | 23 | 77.92 | 180 |

読み取れること:

- **アタックの立つドラムループだけまとも。** それでも誤差 ±3 BPM 程度（後述の量子化が原因）。
- **持続音（シンセパッド）はほぼ検出不能** — 11秒で1個しか返らない。
- **ボーカルチョップはオンセットを拾ってしまう**（272 BPM = チョップの切れ目を拍と誤認）。
- **短いループ（2.8s）は不安定** — 5個しか取れず BPM もダウンビートも当てにならない。
  `audio-design.md` 前提の「4小節ループ」は 174 BPM なら約5.5秒なので、
  **この用途はまさに Beat This が苦手な尺**。

> **重要: タイムスタンプは 0.02 秒グリッドに量子化されている。**
> 返る秒値はすべて 0.02 の倍数（Beat This の hop = 20ms）。
> 174 BPM は 1拍 0.3448s なので 0.34 / 0.36 に丸められ、
> `60 / 中央値` は 171.43 か 176.47 にしかならない。
> **つまり検出値からは原理的に ±2% 程度の BPM 誤差が消せない。**
> 既知BPMのループにビートグリッドが欲しいだけなら、計算で出すほうが常に正確。

→ 使いどころの結論は [decisions.md](decisions.md#q-1-音源をどう調達するか-最重要未決定) の Q-1 追記を参照。

#### PCM の渡し方【落とし穴・解決済み】

Godot 4.4+ は `.wav` を既定で **QOA 圧縮**としてインポートする
（`.import` の `compress/mode=2`）。したがって `AudioStreamWAV.data` は生 PCM ではなく、
そのまま `DetectPCM()` に渡しても意味がない。

**解決策: `FileAccess` で元の `.wav` を読み、RIFF を自前で解釈する。**
`beat_check.gd::_parse_wav()` が PCM 8/16/24/32-bit と IEEE float 32/64-bit、
および `WAVE_FORMAT_EXTENSIBLE`(0xFFFE) に対応済み。インポート設定に一切依存しない。
sample_rate / channel_count もヘッダから正確に取れる。

- `DetectPCM(pcm, channel_count, sample_rate)` の `pcm` は**インターリーブ**のまま渡してよい
  （内部でモノにダウンミックスされる）。長さが `channel_count` で割り切れることだけ守る。
- 再生用の `AudioStreamWAV` も**パース済み PCM から組み直す**と、検出した音と再生する音が
  必ず一致する（QOA 往復を挟まない）。
- 制約: `FileAccess` で元 `.wav` を読むので、**エクスポート後の pck には元ファイルが入らない**。
  検証ツール専用の手法であり、本編で使うなら音源を `res://` の非インポート資産として
  同梱するか、PDJE 側のデコーダ（= DetectMusic ルート）を使うこと。

#### DetectMusic の最小手順【2026-07-22 確定】

`DetectMusic()` は PDJE の DB に音源が登録されている必要がある。
**`InitPlayer()` は不要**（登録だけで通ることを実行して確認した）。最小列は:

```gdscript
engine.InitEngine("user://pdje/rootdb")            # -> true
if engine.SearchMusic(title, composer).is_empty():
    engine.InitEditor(composer, "none", "user://pdje/editor")   # -> true
    var editor = engine.GetEditor()
    editor.ConfigNewMusic(title, composer, "res://audio/loops/x.wav")  # -> true
    var arg := PDJE_EDITOR_ARG.new()               # 1行につき1個。使い回し禁止
    arg.InitMusicArg(title, "174", 0, 0, 4)
    editor.AddLine(arg)                            # -> true
    editor.render("beatcheck_track")               # -> "RENDER COMPLETE"
    editor.pushToRootDB(title, composer)           # -> true
var result := detector.DetectMusic(engine, title, composer, bpm)
```

- `ConfigNewMusic()` は **`res://` パスをそのまま受け付ける**
  （同梱サンプルは `G://YMCA.wav` のような絶対パスを渡しているが、絶対パス化は不要だった）。
- DB は必ず `user://` に置く。サンプルの `res://rootdb` はエクスポート後に書き込めない。
- **PDJE は `<cwd>/logs/pdjeLog.txt` にログを書く**（プロジェクトルートに `logs/` ができる）。
  `.gitignore` 済み。
- 結果は DetectPCM と**完全に一致**した（同じループで beats/downbeats とも同値）。
  入力経路が独立しているのに一致するので、上の精度の限界は
  PCM の作り方ではなく**モデルと後処理そのものの特性**と判断してよい。

#### 検出結果を譜面に落とす — `BeatGrid`【2026-07-22 実装済み】

上の精度問題は、**外部知識を2つ足すと消える**。実装は
[`data/charts/beat_grid.gd`](../data/charts/beat_grid.gd)（`class_name BeatGrid`）。

1. **BPM はファイル名に書いてある**（サンプルパックの慣習: `..._175_...`）。
   数字が複数ある場合（`TSP_ENEIV2_175_...` は "2" と "175" を含む）は
   **自動検出した BPM に最も近いものを採用する**。
   検出器がやりがちな倍速／半速の取り違えを許容するため、
   候補 c と検出値 d の距離は `min over k∈{0.25,0.5,1,2,4} of |c - d·k| / c` で測る。
2. **ループは 2^n 小節**。`bars_raw = loop_length × nominal_bpm / 240` を
   最も近い2の冪に丸める。

この2つから **BPM が厳密に決まる**:

```
bpm = bars × 240 / loop_length
```

実測（全6ループ）— `bars_raw` はすべて **誤差ゼロで 2 の冪**に乗った:

| ループ | 検出BPM | ファイル名 | bars_raw | 確定BPM | 音符数 |
| --- | ---: | ---: | ---: | ---: | ---: |
| FL_BJ_174_Synth_Pad | 0.00 | 174 | 8.000 | 174.001 | 1 |
| SS_XLLRB_150_vocal_chop | 272.73 | 150 | 8.000 | 150.000 | 35 |
| TSP_ENEIV2_175_drum | 171.43 | 175 | 16.000 | 175.000 | 44 |
| TSP_HLZ_174_drum_shaker | 176.47 | 174 | 4.000 | 174.000 | 16 |
| TSP_QUARTZ_174_drum | 120.00 | 174 | 2.000 | 173.999 | 4 |
| shs_ins_180_kit | 77.92 | 180 | 16.000 | 180.000 | 23 |

**検出BPMが 77.92 や 272.73 と大外ししても、確定BPMは正しい。**
検出は「どの数字が BPM か」を選ぶためだけに使い、グリッドそのものは計算で出す。

そのうえで **検出したビートを16分音符にスナップ**して譜面にする
（`BeatGrid.snap_to_steps()`）。ステップ番号（0〜`bars×16`）で保持するので
BPM を変えてもグリッドは壊れない。ループ終端に乗ったビートは次周の step 0 に畳む。
スナップ時の移動量は実測でドラムループなら平均 14〜20 ms（最大は16分の半分＝約43 ms）。

レーン割り当ては `BeatGrid.assign_lanes()`。ループ名をシードにした固定乱数なので
**譜面は実行のたびに変わらない**。直前と同じレーンは避ける。

#### 譜面の書き出しと再生

`scenes/tools/beat_check.tscn` の **Export chart** ボタン（CLI は `-- --export-chart`）が
`res://data/charts/<ループ名>.json` を書き出す。フォーマットは既存の
`demo_chart.json` の上位互換:

```json
{
  "bpm": 175.0, "nominal_bpm": 175, "bars": 16,
  "loop": true, "loop_length": 21.942857, "loop_frames": 967680,
  "steps_per_loop": 256,
  "notes": [ { "time": 0.342857, "lane": 3, "step": 4 } ]
}
```

- `time`（秒）は既存の読み取りコードと互換。`step`（16分番号）が拍ベースの種
  → [decisions.md](decisions.md) Q-2。
- **`loop_frames` が肝**。再生はインポート済み（QOA）リソースを使いつつ、
  ループ点だけ元PCMのフレーム数で上書きする（`loop_begin=0` / `loop_end=loop_frames`）。
  こうすると **音のループ周期と譜面の周期が厳密に一致**し、QOA のパディングも切り落とせる。
  ランタイムに自前WAVパースが要らないので、エクスポートしても壊れない。

`Conductor` にループ対応を追加した（`play_song(stream, bpm, loop_length)`）。
`song_position` はループ点で0に戻らず **`周回数 × loop_length + 周内位置`** として
increase し続けるので、譜面は1本の連続タイムラインとして書ける。

`scenes/rhythm/rhythm_game.gd` は既定でこの譜面を読み、
**同じパターンを毎周発行し続ける無限ループ**として動く。実測（実オーディオデバイス）:

| 周 | 実測 t | 期待値 | ずれ |
| ---: | ---: | ---: | ---: |
| 2 | 21.947 | 21.943 | +4 ms |
| 3 | 43.888 | 43.886 | +2 ms |
| 4 | 65.829 | 65.829 | 0 ms |

3周でずれ 4 ms 以内 = **音のループと譜面グリッドは同期している**。
未処理ノート数も毎周一定（pending 40 / active 4）で、無限に伸び続けない。
再生確認は `-- --selftest <秒>` で自動化してある（観測のみ・自動プレイはしない）。

#### クリック再生の実測

`beat_check.gd` は毎フレーム「再生位置が次のビート秒を跨いだか」で発火する素朴な方式。
`--autoplay` 引数で全クリックのズレをログ出力して実測したところ、
**ドリフトは +0〜6 ms**（60fps の1フレーム 16.7ms 未満）に収まった。検証用途には十分。
再生位置は `Conductor` と同じ
`get_playback_position() + AudioServer.get_time_since_last_mix() - output_latency`。
より厳密にやるなら `AudioServer` 時刻基準の先読みスケジュールに置き換える。

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
