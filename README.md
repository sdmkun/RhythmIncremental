# RhythmIncremental

A **rhythm game + incremental game** prototype for **Godot 4.7.1** (GDScript).

Play a 4-lane chart to earn **Beats**, then spend Beats in a **skill tree** for
score multipliers, passive idle income, and wider hit windows — the classic
rhythm ⇄ incremental feedback loop.

## Run it
1. Open **Godot 4.7.1**, import this folder (`project.godot`).
2. Press **F5**. Main scene is `scenes/main_menu/main_menu.tscn`.
3. Controls: **D F J K** hit the four lanes, **Esc** returns to the menu.

The prototype runs **with no external addons installed** — timing and judgement
are done in GDScript, and the demo chart has no audio file (the clock still
runs, so it's fully playable). Drop an `AudioStream` into the chart to hear it.

## Planned integrations
| Concern | Prototype stand-in | Library to install |
|---|---|---|
| Rhythm audio + timing + judgement | `autoload/conductor.gd`, `_judge_lane()` | **Project-DJ-Godot** (RROP) — `addons/Project_DJ_Godot/INSTALL.md` |
| Skill / passive tree authoring + runtime | `data/skills/skill_data.gd` | **Yggdrasil** (IncludeSpark) — `addons/yggdrasil/INSTALL.md` |

Both are wired as clearly-commented **INTEGRATION POINT** blocks so they can be
swapped in without restructuring the game.

## Project layout
```
project.godot              # Godot 4.7.1 config, autoloads, D/F/J/K input map
icon.svg
autoload/
  game_state.gd            # GameState singleton: Beats economy, upgrades, save/load, idle income
  conductor.gd             # Conductor singleton: musical clock (→ swap for PDJE Core)
scenes/
  main_menu/               # entry, routing
  rhythm/                  # 4-lane falling-note gameplay + judgement
  skill_tree/              # incremental progression screen
data/
  charts/demo_chart.json   # sample chart (time/lane)
  skills/skill_data.gd     # SkillData: upgrade definitions (→ swap for Yggdrasil tree)
addons/
  Project_DJ_Godot/INSTALL.md
  yggdrasil/INSTALL.md
CLAUDE.md                  # guidance for continuing in Claude Code
```

## Next steps
See `CLAUDE.md` for a task list to continue in Claude Code.
