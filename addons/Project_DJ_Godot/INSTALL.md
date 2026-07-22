# Project-DJ-Godot (PDJE) — install & integration

C++/GDExtension DJ & rhythm audio engine by RROP. License: LGPL-2.1.
Store page: https://store.godotengine.org/asset/rrop/project-dj-godot/
Source: https://github.com/Rliop913/Project_DJ_Godot
Docs: https://rliop913.github.io/Project-DJ-Engine-Docs/

> The prototype in this project runs **without** PDJE (see `autoload/conductor.gd`).
> Install PDJE when you want microsecond-accurate, OS-level timing + the built-in
> Judge module instead of the GDScript timing/judgement used here.

## Requirements
- Godot **4.5+** (this project targets 4.7.1). ✔ compatible.
- Input/Judge modules are **Windows-first**; Core audio works on Win/Linux/macOS.
- Download is large (~723 MB prebuilt, Git LFS artifacts).

## Install (recommended — the maintainer's script)
1. Clone the plugin repo somewhere outside this project:
   ```
   git clone https://github.com/Rliop913/Project_DJ_Godot.git
   ```
2. Copy `Update_Project_DJ_Godot.bat` (Windows) or `.sh` into this project root:
   `C:\Users\sdmkun\Documents\GodotProjects\RhythmIncremental\`
3. Run it from the project root — it pulls the prebuilt addon into
   `addons/Project_DJ_Godot/` (replacing this placeholder folder):
   ```
   Update_Project_DJ_Godot.bat
   ```
4. Open the project in Godot, enable the plugin in
   **Project → Project Settings → Plugins**, and restart the editor so the
   GDExtension (`PDJE_Wrapper.gdextension`) loads.

## Alternative: Godot Asset Store
In the editor: **AssetLib** tab → search "Project-DJ-Godot" → Download → Install.

## Wiring it into this project
- `autoload/conductor.gd` is the single timing source. Replace its
  AudioStreamPlayer clock with PDJE's Core timeline position.
- Connect PDJE's Judge signals (payload: lane/note id + timing offset in µs) and
  route hits/misses into `RhythmGame._register_hit()` / `_register_miss()` in
  `scenes/rhythm/rhythm_game.gd`, instead of `_judge_lane()`.
- PDJE ships a rhythm starter scene `GAME_TEMPLATE.tscn` and agent docs at
  `addons/Project_DJ_Godot/ProjectDJGodot_Agent_Docs` — good reference material
  for Claude Code.
- Q&A helper for the codebase: https://github.com/Rliop913/AskToPDJE
