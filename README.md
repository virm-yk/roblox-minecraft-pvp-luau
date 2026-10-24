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
| **Collision** | **Implemented, not connected.** The collision core (`Collision.moveEntity`, per-axis clipping, step-up, penetrating-block recovery) is complete and covered by headless tests, and a static world is maintained by `CollisionAdapter.watch` — but nothing calls `moveEntity` yet, so collision has **zero** effect on gameplay. |
| **Combat** | **Disabled.** `CombatConfig.Enabled = false`. The server still accepts `CombatAttack` and answers every attack with `{ Accepted = false, Reason = "CombatDisabled" }`. `CombatMath` and `RaycastHitbox` remain all-stubs that return nil/false, which the callers treat as a reject. |
| **Input pipeline** | Implemented. Client gathers and sequences input, server validates, queues, and consumes one frame per tick. |
| **Networking** | Implemented. Snapshots at 10 Hz (schema 3, including the server-measured rig offset), client-side prediction with replay-based reconciliation, generation-based resync. `Seq` and `ServerTick` are separate clocks and are never compared. |
| **Character control** | The custom controller is **enabled**: `MovementConfig.Control.Enabled = true` anchors the root and zeroes `Humanoid.WalkSpeed` / `JumpPower` / `AutoRotate`. Since movement is stubbed, the character is anchored and immobile by design. |

No Roblox Studio Play test has been performed on this revision. See
[KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## What changed in this revision

1. **Clock separation.** `MovementState.fromSnapshot`, `MovementState.isPlausible` and
   `Reconcile.parseSnapshot` no longer reject a state because
   `LastAppliedInputSeq > ServerTick`. The two counters advance at different rates and
   drift by design; `Seq` now only orders/acknowledges/replays input, and `ServerTick`
   only drives simulation time and snapshot ordering.
2. **Collision world lifetime.** Both entry points use `CollisionAdapter.watch` instead
   of a one-shot build. The world is rebuilt (into a **new** `Collision.World`) when
   `workspace.World` appears, disappears, is renamed or reparented, gains or loses
   descendants, or when a registered part's geometry changes. Rebuilds are debounced by
   `MovementConfig.Collision.RebuildDebounceSeconds`. A missing folder at startup is no
   longer permanent and no box is ever registered twice. Parts that would exceed the
   per-box cell cap are **rejected and reported** (`Category = "Oversized"`), never
   clipped, and a single oversized part can no longer abort a rebuild.
3. **Runtime rig offset.** A new shared module, `RigOffset`, resolves the presentation
   distance between the simulation's feet origin and the `HumanoidRootPart` centre from
   the live rig (`Humanoid.HipHeight + HumanoidRootPart.Size.Y / 2`). The hard-coded
   `Units.RootToFeetOffsetStuds = 3` is gone. The server measures once per session and
   publishes the result in every snapshot as `RootToFeetOffsetStuds`; the client presents
   with that exact value, so the two sides can never fight over root height. The client
   also measures its own copy for a one-time disagreement warning. Unmeasurable rigs
   fall back to the documented `Units.RootToFeetOffsetStudsFallback` with a warning.
   The snapshot schema is now **3** (`SchemaVersion = 3`); the movement `State` shape is
   unchanged. The Minecraft hitbox (`MovementConfig.Hitbox`) is unchanged and
   independent of rig size.

Nothing else changed: movement is still stubbed, combat is still disabled, and no
sprint/jump/gravity/special-block behaviour was added.

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
│       ├── RaycastHitbox.lua
│       └── RigOffset.lua
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

1. Create the `ReplicatedStorage.MinecraftShared` **Folder** and all 13 ModuleScripts
   inside it. Module names must match exactly — they are referenced by
   `require(script.Parent.<Name>)`.
2. `InputController` and `InputDebugOverlay` must be **siblings of `MinecraftClient`**
   under `StarterPlayerScripts`; the client requires them through
   `require(script.Parent:WaitForChild(...))`.
3. `workspace.World` does **not** have to exist before the scripts start. The adapter
   builds an empty world, then rescans when the folder appears or changes. Parts are
   registered only while it exists; deleting the folder produces an empty world rather
   than stale geometry.
4. Part geometry is assumed to be axis-aligned, unrotated blocks on a 4-stud grid
   (1 block = 4 studs) aligned to the origin. Rotated parts, non-`Part` classes, ball
   and cylinder shapes, unanchored parts, and boxes over `MaxCellsPerBox` are rejected
   with a report entry; they are never approximated or clipped.
5. The root-to-feet offset is measured per character from `Humanoid.HipHeight` and
   `HumanoidRootPart.Size.Y`. If a rig cannot be measured, both scripts log a warning
   naming the reason and use the documented fallback (3 studs).

## Excluded on purpose

Minecraft reference source is intentionally excluded from this repository. The baseline
was derived by reading a Java 1.9 decompile (`Block`, `World`, `Entity`,
`EntityLivingBase`, `EntityPlayer`, `EntityPlayerMP`, `NetHandlerPlayServer`,
`AxisAlignedBB`, `MovementInput`, `ItemSword`, `ItemTool`, `CombatRules`), but **none
of that source is included here, and neither are any MCP metadata, jars, changelogs, or
recovered original scripts**. This repository contains only the 17 Luau install files
and the three documents that describe them.

## Known issues

Deliberately recorded in [KNOWN_ISSUES.md](KNOWN_ISSUES.md). Remaining: no per-block
slipperiness channel (F2), the oversized-box authoring constraint, movement stubbed,
collision not connected to movement, combat disabled, and no Studio Play test of this
revision.
