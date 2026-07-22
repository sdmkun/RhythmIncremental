# CLAUDE.md — RhythmIncremental

Guidance for continuing this project in Claude Code.

> **Read [`docs/`](docs/) before any feature work.** This file describes *how the
> project currently works*; `docs/` describes *where it is going* and *why*.
> Start with [`docs/vision.md`](docs/vision.md) (the three design pillars) and
> [`docs/decisions.md`](docs/decisions.md) (settled vs. still-open questions —
> check it before re-litigating a decision).

## What this is
A **rhythm game + incremental game** prototype in **Godot 4.7.1 / GDScript**.
Earn Beats by playing charts → spend Beats in a skill tree → upgrades boost
scoring and add passive idle income. Fully playable today with **no addons**.

The intended direction is bigger than the current prototype: skills should
**change the song's genre** (exclusive choices), play and skills should apply
**realtime audio FX**, and completing a full song should trigger a
**prestige reset with meta-progression**. See [`docs/vision.md`](docs/vision.md).

## Architecture
- **Autoloads** (singletons, see `project.godot [autoload]`):
  - `GameState` (`autoload/game_state.gd`) — currency (Beats), upgrade levels,
    derived multipliers, passive idle loop, JSON save/load at `user://save.json`.
  - `Conductor` (`autoload/conductor.gd`) — the musical clock. Rhythm scene reads
    `Conductor.song_position` each frame.
- **Scenes** are deliberately thin: each `.tscn` is just a root node + script;
  UI is built procedurally in `_ready()`. Easy to diff, no fragile node paths.
  - `scenes/rhythm/rhythm_game.gd` — spawn/move/judge notes, pay Beats.
  - `scenes/skill_tree/skill_tree.gd` — buy upgrades from `SkillData`.
  - `scenes/main_menu/main_menu.gd` — routing.
- **Data**: `data/charts/demo_chart.json`, `data/skills/skill_data.gd` (`SkillData`).

## The two libraries
- **Yggdrasil** (GDScript, MIT) — **installed and wired in.** Plugin enabled in
  `project.godot` ([editor_plugins] + `YggdrasilLoader`/`YggdrasilSerializer`
  autoloads). `scenes/skill_tree/skill_tree.gd` builds a live `YggdrasilTree` +
  `YggdrasilBuilder` graph from `SkillData` in code each time the scene loads
  (Registry/Loader are skipped — `SkillData` stays the source of truth for
  cost/effect/prerequisites; Yggdrasil only owns the visual graph/node
  states). Buying still goes through `GameState.buy_upgrade()`. Note:
  `YggdrasilNodesService._create_node_from_data()` overwrites a node's
  `external_id` with its display name, so `skill_tree.gd` keys nodes by
  `YggdrasilNode.id` (int) instead, via its own `_id_to_skill` map.
- **Project-DJ-Godot** (C++/GDExtension, LGPL-2.1) — **installed but not yet
  wired in.** Install: `addons/Project_DJ_Godot/INSTALL.md`.
  The key insight (see [`docs/decisions.md`](docs/decisions.md) D-3/D-4) is that
  PDJE splits cleanly into two halves that can be adopted **independently**:
  - **Audio half — likely to adopt.** `MusPanelWrapper.SetMusic(title, on/off)`
    gives per-layer toggling, `getFXHandle()` + `SetFXArg()` gives 18 realtime
    FX, and `PDJE_AI` (bundled Beat This ONNX model) extracts beat/downbeat
    timestamps from arbitrary audio. This maps almost 1:1 onto the genre-shift
    and realtime-FX pillars → [`docs/audio-design.md`](docs/audio-design.md).
    **The `PDJE_AI` half is proven working** by `scenes/tools/beat_check.tscn`
    (a standalone verification tool, not part of the game): both `DetectPCM`
    and `DetectMusic` run, and the minimal DetectMusic init sequence is now
    documented in `docs/audio-design.md`. Its accuracy turned out to be too
    coarse for our own known-BPM loops — see `docs/decisions.md` Q-1.
  - **Judge/chart half — deferred.** Its Judge/Input modules expect charts
    authored through PDJE's own internal DB (`PDJE_EDITOR_ARG`, rail-id device
    mapping, per-frame `InputLine.emit_input_signal()` pumping); there is no
    documented path to feed it `data/charts/demo_chart.json`. Judgement stays
    in GDScript for now.

## Conventions
- Godot **4.7.1**, GDScript, `config_version=5`. GL Compatibility renderer.
- Prefer typed GDScript (`var x: int`, `-> void`). Keep scenes script-driven.
- Keep the game runnable **without** addons until each integration is complete;
  guard addon usage behind checks / feature flags where practical.
- Input actions: `lane_0..lane_3` = D/F/J/K; `ui_cancel` = Esc.

## Suggested next tasks
The three pillars all depend on audio, and there is **no audio in the project
yet** — that is the critical path. Blocking question: how audio is sourced
(`docs/decisions.md` Q-1, still undecided).

1. **Get sound playing.** One loop via `AudioStreamPlayer`, synced to
   `Conductor`, verify latency (`Conductor.output_latency`). Needs no addon.
2. **Exclusive skills.** Add `slot` / `exclusive_group` / `audio_layer` to
   `SkillData` and enforce exclusivity in `skill_tree.gd::_on_node_pressed()`
   (Yggdrasil has no native mutual exclusion). Doable *without* audio →
   [`docs/progression-design.md`](docs/progression-design.md).
3. **Layer toggling** via PDJE `MusPanel` → genre-shift pillar.
4. **Combo/accuracy → `SetFXArg()`** → realtime-FX pillar.
5. **Prestige + meta-progression** (`GameState.upgrade_levels` reset is enough;
   tree state is rebuilt from `SkillData` every load).
6. Move charts from seconds to beat-based before genre/BPM changes land
   (`docs/decisions.md` Q-2).

## Run / debug
- Run: open in Godot 4.7.1, press F5 (main scene = `scenes/main_menu/main_menu.tscn`).
- Save file lives at `user://save.json` (delete to reset progression).
