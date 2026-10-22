# roblox-minecraft-pvp-luau

Consolidated Luau baseline for a Roblox project that targets **Minecraft Java Edition
1.9** behaviour. This repository exists to transfer the baseline into Roblox Studio
for installation and testing. It is a source drop, not a working game.

## Target

Minecraft **Java Edition 1.9** — not 1.8.9, not 1.9.1 or later. Every numeric constant
in `MovementConfig` and `CombatConfig` is annotated with the version it comes from,
because 1.8.9 and 1.9 differ in ways that matter (velocity cutoff, jump handling,
attack cooldowns, sprint gating). Simulation units are explicit: positions are in
**blocks**, velocities are in **blocks per tick**, and studs appear only at the Roblox
boundary inside `MovementMath`.

## Current state — read this before testing

| Area | State |
| --- | --- |
| **Movement** | **Stubbed.** `MovementMath.PHYSICS_IMPLEMENTED = false`. `stepPlayerTick` only clears per-tick collision flags. Position and velocity never change: the character does not move, fall, or slide. It does turn with the camera, because yaw and pitch are copied from the input frame. Sprinting is never granted. |
| **Collision** | **Implemented, not connected.** The collision core (`Collision.moveEntity`, per-axis clipping, step-up, penetrating-block recovery) is complete and covered by headless tests, and a static world is built at startup — but nothing calls `moveEntity` yet, so collision has **zero** effect on gameplay. |
| **Combat** | **Disabled.** `CombatConfig.Enabled = false`. The server still accepts `CombatAttack` and answers every attack with `{ Accepted = false, Reason = "CombatDisabled" }`. `CombatMath` and `RaycastHitbox` remain all-stubs that return nil/false, which the callers treat as a reject. |
| **Input pipeline** | Implemented. Client gathers and sequences input, server validates, queues, and consumes one frame per tick. |
| **Networking** | Implemented. Snapshots at 10 Hz, client-side prediction with replay-based reconciliation, generation-based resync. |
| **Character control** | The custom controller is **enabled**: `MovementConfig.Control.Enabled = true` anchors the root and zeroes `Humanoid.WalkSpeed` / `JumpPower` / `AutoRotate`. Since movement is stubbed, the character is anchored and immobile by design. |

No Roblox Studio Play test has been performed on this baseline. See
[KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## Repository layout

The `roblox/` tree mirrors Roblox Explorer paths. It is not a Rojo project and has no
build step — each `.lua` file is the exact source of one Instance.

```
roblox/
├── ReplicatedStorage/
│   └── MinecraftShared/          -> ReplicatedStorage.MinecraftShared (Folder)
│       ├── MovementConfig.lua
│       ├── MovementState.lua
│       ├── MovementMath.lua
│       ├── Collision.lua
│       ├── CollisionAdapter.lua
│       ├── InputState.lua
│       ├── InputHistory.lua
│       ├── InputQueue.lua
│       ├── Reconcile.lua
│       ├── CombatConfig.lua
│       ├── CombatMath.lua
│       └── RaycastHitbox.lua
├── StarterPlayer/
│   └── StarterPlayerScripts/
│       ├── MinecraftClient.client.lua
│       ├── InputController.lua
│       └── InputDebugOverlay.lua
└── ServerScriptService/
    └── MinecraftServer.server.lua
```

Path-to-Explorer mapping:

- `roblox/ReplicatedStorage/MinecraftShared/<Name>.lua` → `ReplicatedStorage.MinecraftShared.<Name>` — **ModuleScript**
- `roblox/StarterPlayer/StarterPlayerScripts/MinecraftClient.client.lua` → `StarterPlayer.StarterPlayerScripts.MinecraftClient` — **LocalScript** (the `.client` suffix is a filename convention only; the ClassName comes from the manifest)
- `roblox/StarterPlayer/StarterPlayerScripts/InputController.lua` → `StarterPlayer.StarterPlayerScripts.InputController` — **ModuleScript**
- `roblox/StarterPlayer/StarterPlayerScripts/InputDebugOverlay.lua` → `StarterPlayer.StarterPlayerScripts.InputDebugOverlay` — **ModuleScript**
- `roblox/ServerScriptService/MinecraftServer.server.lua` → `ServerScriptService.MinecraftServer` — **Script**

Per-file ClassNames, byte counts, line counts and checksums are in
[INSTALL_MANIFEST.md](INSTALL_MANIFEST.md).

## Installation notes

1. Create the `ReplicatedStorage.MinecraftShared` **Folder** and all 12 ModuleScripts
   inside it. Module names must match exactly — they are referenced by
   `require(script.Parent.<Name>)`.
2. `InputController` and `InputDebugOverlay` must be **siblings of `MinecraftClient`**
   under `StarterPlayerScripts`; the client requires them through
   `require(script.Parent:WaitForChild(...))`.
3. **The `World` folder must exist in the place before the server script starts**, and
   must contain the part geometry the collision world should register. The collision
   world is built exactly once, at script load, and is never rebuilt.
4. Part geometry is assumed to be axis-aligned, unrotated blocks on a 4-stud grid
   (1 block = 4 studs) aligned to the origin.

## Excluded on purpose

Minecraft reference source is intentionally excluded from this repository. The baseline
was derived by reading a Java 1.9 decompile (`Block`, `World`, `Entity`,
`EntityLivingBase`, `EntityPlayer`, `EntityPlayerMP`, `NetHandlerPlayServer`,
`AxisAlignedBB`, `MovementInput`, `ItemSword`, `ItemTool`, `CombatRules`), but **none of
that source, and no MCP metadata, jar, changelog, or recovered original scripts, is
included here**. This repository contains only the 16 Luau install files and the three
documents that describe them.

## Known issues

Deliberately recorded and **not fixed** in this baseline: see
[KNOWN_ISSUES.md](KNOWN_ISSUES.md). The two that affect testing first are the
`Seq`/`ServerTick` comparison and the hard-coded `RootToFeetOffsetStuds = 3`.
