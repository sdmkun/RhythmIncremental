# Yggdrasil — install & integration

Node-tree / skill-tree editor + runtime by IncludeSpark. License: MIT.
Store page: https://store.godotengine.org/asset/includespark/yggdrasil/
Source: https://github.com/Oen44/yggdrasil

> The prototype uses a plain data list in `data/skills/skill_data.gd` so it runs
> without Yggdrasil. Install Yggdrasil to author the tree visually and get
> prefabs, grid-snapping, validation, and a runtime builder.

## Requirements
- Godot **4.7+** (this project targets 4.7.1). ✔ compatible. Small (~112 KB).

## Install (Godot Asset Store — easiest)
1. In the editor open the **AssetLib** tab → search "Yggdrasil" → Download →
   Install (it lands in `addons/yggdrasil/`, replacing this placeholder folder).
2. Enable it in **Project → Project Settings → Plugins**.
3. Restart the editor; the tree editor dock/tab appears.

## Alternative: from source
```
git clone https://github.com/Oen44/yggdrasil.git
```
Copy the repo's `addons/yggdrasil/` folder into this project's `addons/`, then
enable the plugin.

## Wiring it into this project
Yggdrasil's runtime flow is **Registry → Loader → Builder**:
1. Build your skill tree in the Yggdrasil editor and save the tree resource.
2. Register it, load it via the Loader, and use the Builder to turn the resource
   into a live tree "with a few lines of code" (see the repo README/examples).
3. In `scenes/skill_tree/skill_tree.gd`, replace the `SkillData` list rendering
   with the built tree. Bind each node's buy action to
   `GameState.buy_upgrade(id)` and use node/edge connections for prerequisites
   (currently `SkillData.is_unlocked()`).
4. Keep effect application in `GameState._recompute_multipliers()` — just map
   Yggdrasil node ids/metadata to the same `effect`/`per_level` fields.
