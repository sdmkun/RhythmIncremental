# 進行設計 — スキルツリー / 排他 / プレステージ

[vision.md](vision.md) の柱1（ジャンル選択）と柱3（プレステージ）の実装設計。
音側の前提は [audio-design.md](audio-design.md) を参照。

## スキル → 音のマッピング【提案】

スキルを2種類に分ける。

### 1. レイヤースキル（曲を作る／柱1の主役）

スロットにジャンルバリアントを差す。**同一スロット内は排他。**

| スロット | バリアント例 |
| --- | --- |
| Drums | House / DnB / Lo-Fi / Trap |
| Bass | House / DnB / Lo-Fi / Trap |
| Chords | House / DnB / Lo-Fi / Trap |
| Lead | House / DnB / Lo-Fi / Trap |
| Atmosphere | House / DnB / Lo-Fi / Trap |

全5スロットが埋まる = **1曲完成 = プレステージ解禁**。

ジャンルを混ぜる自由は残す（Drums=DnB × Chords=Lo-Fi など）。
混ぜた組み合わせにボーナスを付けると、ビルドの探索が楽しくなる。【提案】

### 2. 強化スキル（現行の仕組み）

`score_mult` / `idle` / `window` の数値強化。既存の `SkillData` がそのまま使える。
レイヤースキルの取得コストを賄うために回す。

## SkillData スキーマの拡張【提案】

現行 `data/skills/skill_data.gd` の各定義に、レイヤースキル用フィールドを追加する。

```gdscript
&"drums_house": {
    "name": "House Kick",
    "desc": "4つ打ちのドラムループを追加。",
    # --- 既存 ---
    "effect": "layer",          # 新しい effect 種別
    "per_level": 0.0,
    "max_level": 1,             # レイヤースキルは1レベルのみ
    "base_cost": 200, "cost_growth": 1.0,
    "requires": [],
    # --- 追加 ---
    "slot": &"drums",           # どのスロットを埋めるか
    "exclusive_group": &"drums",# 同じグループは1つしか取れない
    "audio_layer": "drums_house", # MusPanel の music title と対応
},
```

- `exclusive_group` が同じスキルは**同時に1つしか取得できない**
- `slot` が全種類埋まったかどうかでプレステージ解禁を判定
- `audio_layer` が [audio-design.md](audio-design.md) の `LoadMusic()` の title に対応

`GameState._recompute_multipliers()` に `"layer"` の分岐を追加し、
有効レイヤー集合を導出して音側へ渡す。

## 排他スキルの実装【重要】

**Yggdrasil には排他（mutual exclusion）の機能がない。** 自前で実装する必要がある。

幸い `scenes/skill_tree/skill_tree.gd` は既に**独自のクリックハンドラ**を持っている
（Yggdrasil 標準の `allocation_service.on_node_pressed` は切断済み）ので、
そこに排他判定を足すだけでよい。

```gdscript
func _on_node_pressed(node: YggdrasilNodeButton) -> void:
    var id: StringName = _id_to_skill[node.id]
    # ここに排他チェックを追加する
    if _is_blocked_by_exclusive(id):
        _show_message("別のジャンルを選択済みです。")
        return
    ...
```

排他が発動している選択肢は**視覚的にも潰す**こと（グレーアウト or ×表示）。
Yggdrasil のノード状態 (`set_state()`) と border テクスチャで表現できる。

> **注意（既知の落とし穴）:** `YggdrasilNodesService._create_node_from_data()` は
> ノードの `external_id` を表示名で上書きしてしまう。そのため `skill_tree.gd` は
> 整数 `YggdrasilNode.id` を自前の `_id_to_skill` で引いている。
> ノードとスキルを紐付ける新コードでも `external_id` を信用しないこと。

### ツリーの形をどうするか

排他を入れるなら、現在の「一本道の前提条件ツリー」より
**スロットごとに分岐する放射状／グリッド状**のほうが構造が伝わりやすい。【提案】

```
        [Drums]              各スロットから
       /   |   \             ジャンルが分岐し、
   House  DnB  Lo-Fi         1つしか選べない
```

## プレステージ【確定：やる／【提案】：詳細】

### 解禁条件

**全スロットが埋まったら**（＝1曲完成）プレステージ可能。【提案】

数値の閾値ではなく構造的達成にすることで、
「曲が完成したから次へ行く」という物語が成立する。

### リセットされるもの / 残るもの

| | リセット | 残る |
| --- | :---: | :---: |
| `beats`（所持通貨） | ● | |
| `upgrade_levels`（スキル取得状況） | ● | |
| 曲のレイヤー構成 | ● | |
| `lifetime_beats` | | ● |
| プレステージ通貨 | | ● |
| メタアンロック状況 | | ● |

**実装上の利点:** 現在の Yggdrasil 統合は `GameState` を唯一の真実とし、
ツリーは毎回 `SkillData` から再構築している（`YggdrasilSerializer.save_tree_state()` は
呼んでいないので `user://` にツリー状態は残らない）。
そのため **`GameState.upgrade_levels` をクリアするだけでツリーのリセットが完結する。**

### メタプログレッション【提案】

ユーザーの構想「最初はアンロックできなかったスキルのアンロック」を軸に。

プレステージ通貨（仮称 **Master Tape**）を獲得し、恒久的な解禁に使う:

| 解禁の種類 | 例 | 効果 |
| --- | --- | --- |
| **新ジャンル** | Trap / Jazz バリアント解禁 | 選択肢が増える（横の広がり） |
| **新スロット** | 6本目のレイヤー（Vocal など） | 曲がリッチになる（縦の深さ） |
| **ルール破り** | 1スロットに2バリアント同時 | 排他制約そのものを緩める |
| **恒久強化** | 開始時 Beats、初期倍率 | ループの高速化 |

「ルール破り」系は、一度体験した制約を壊すので**メタ進行の快感が大きい**。
おすすめの目玉解禁。

`SkillData` に `unlock_requires_meta: &"trap_genre"` のようなフィールドを足し、
メタ解禁されるまでツリーに出さない（or ロック表示）ことで実装できる。

## 実装順【提案】

| 段階 | やること | 前提 |
| --- | --- | --- |
| 1 | `SkillData` に `slot` / `exclusive_group` / `audio_layer` を追加 | なし |
| 2 | `skill_tree.gd` に排他チェック + 視覚表現 | 段階1 |
| 3 | レイヤー有効集合を `GameState` から音側へ配線 | [audio-design.md](audio-design.md) 段階1 |
| 4 | プレステージ解禁判定 + リセット処理 | 段階1 |
| 5 | メタ通貨とアンロック | 段階4 |

段階1〜2 は**音源がなくても着手できる**（排他ロジックとUIだけ先に作れる）。
