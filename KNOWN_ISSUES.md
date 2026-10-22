# Known issues

Recorded deliberately. **None of these are fixed in this baseline.** They are listed so
that installation and testing start from an accurate picture, and so that whoever picks
this up does not discover them by accident.

Line references are to the files in this repository.

---

## F1 — Client `Seq` is compared against `ServerTick` (two different clocks)

`Seq` is a client-side input sequence: a counter the client increments once per predicted
step. `ServerTick` is server simulation time: a counter the server advances once per
fixed 1/20 s tick. They are unrelated counters, and the baseline compares them anyway:

- `MovementState.isPlausible` rejects a state when
  `state.LastAppliedInputSeq > state.ServerTick`
  (`ReplicatedStorage/MinecraftShared/MovementState.lua:320`).
- `Reconcile.parseSnapshot` rejects a snapshot on the same comparison
  (`ReplicatedStorage/MinecraftShared/Reconcile.lua:85`).
- `MovementState.fromSnapshot` performs the equivalent check on the client side.

**Why it is wrong.** The server drops its tick backlog rather than spiralling
(`ServerScriptService/MinecraftServer.server.lua:405` sets `tickAccumulator = 0`), so
under load the server's `ServerTick` advances **slower** than wall clock, while the
client's `Seq` keeps advancing at its own prediction rate
(`StarterPlayer/StarterPlayerScripts/MinecraftClient.client.lua:243`). Once the client's
`Seq` overtakes the server's `ServerTick`, the server considers its own freshly computed
state implausible, calls `requestResync(session, "InvalidState")`
(`MinecraftServer.server.lua:294-296`), bumps the generation, and the client resets
`Seq` to 1. Under sustained server lag this repeats indefinitely.

**Not fixed, because fixing it changes the state contract.** The intended invariant is
`LastAppliedInputSeq` bounded by the number of inputs actually applied, not by
simulation time; the server would need to track that count separately (or the snapshot
would need to carry it). This is a design change, not a typo.

---

## F2 — No per-block slipperiness metadata channel

Minecraft applies ground friction by multiplying a global drag factor by the
slipperiness of the block beneath the entity: 0.6 for normal blocks, 0.8 for ice, 0.98
for packed ice, and so on. The baseline collision world stores **only solid geometry**
— there is no channel through which a block can report a friction value.

As a result:

- `MovementConfig.Physics.SlipperinessDefault = 0.6`
  (`ReplicatedStorage/MinecraftShared/MovementConfig.lua:79`) is a **constant stand-in**,
  not a lookup.
- The collision core has no metadata callback, no material tag, and no way to ask "what
  is under this box". `Collision.moveEntity` returns `OnGround` and per-axis collision
  flags, and nothing else.
- Ice, packed ice, frosted ice, slime, and soul sand therefore cannot behave correctly
  once movement is written. They will behave like stone.

This is a missing data channel, not a missing formula: the drag maths is specified, the
input to it is not available.

---

## F5 — The collision world is built once and never rebuilt

`CollisionAdapter.fromWorkspace` (`ReplicatedStorage/MinecraftShared/CollisionAdapter.lua:299`)
is called at file scope by both entry points:

- `ServerScriptService/MinecraftServer.server.lua:53`
- `StarterPlayer/StarterPlayerScripts/MinecraftClient.client.lua:36`

Consequences:

- The world is a **snapshot taken at script load**. Parts added, moved, resized, or
  destroyed afterwards are not reflected. There is no rescan, no dirty flag, and no
  rebuild entry point that anything calls.
- If `workspace.World` does not exist yet when the server script runs, the adapter
  reports a missing folder and the world stays **empty for the entire session** — every
  collision query will report open air. Create the folder and its contents before the
  server script starts.
- Both the server and the client build their own world independently, at different
  times. If the geometry changes between the two loads, the two worlds disagree, and
  client prediction will drift from server simulation.

**Not fixed.** A rebuild path needs an invalidation trigger (attribute change, signal,
or explicit regenerate call) and a decision about what happens to in-flight prediction.

---

## Collision adapter rejects oversized boxes above its cell cap

Each registered box is decomposed into grid cells. `MovementConfig.Collision.MaxCellsPerBox = 4096`
(`ReplicatedStorage/MinecraftShared/MovementConfig.lua:110`) caps that decomposition, and
`Collision.lua:226-231` returns an **error** (not a silent truncation, not an
approximation) when a box would exceed it.

At 1 block = 1 cell, a merged part larger than roughly 16×16×16 blocks cannot be
registered. Large solid regions must be split into smaller parts. This is intentional —
silently clamping would make collision quietly wrong — but it is a real authoring
constraint, and it is not worked around anywhere in this baseline.

---

## `RootToFeetOffsetStuds = 3` assumes one specific R15 configuration

`MovementConfig.Units.RootToFeetOffsetStuds = 3`
(`ReplicatedStorage/MinecraftShared/MovementConfig.lua:64`) is a **hard-coded constant**,
already marked `[UNKNOWN]` in the source. It assumes an R15 rig with `HipHeight = 2`
plus a 1-stud half-root.

Every feet↔root conversion inherits it:

- `MovementMath.feetBlocksToRootStuds` (`MovementMath.lua:58`)
- `MovementMath.rootStudsToFeetBlocks` (`MovementMath.lua:63`)
- `MovementMath.toRootCFrame`, and therefore every position written to the character
- the initial spawn position computed by the server

If the real rig differs — R6, a custom rig, a different `HipHeight`, or a scaled
character — every position is offset vertically by the difference, and the character
will appear to float or sink by that amount. This baseline has no rig-type detection and
does not read `Humanoid.HipHeight` at runtime.

**Not fixed.** The correct fix is to read the offset from the live rig once and thread it
through, which requires a Studio measurement that has not been made.

---

## Movement remains stubbed

`MovementMath.PHYSICS_IMPLEMENTED = false` (`ReplicatedStorage/MinecraftShared/MovementMath.lua:44`).

`stepPlayerTick` clears the per-tick collision flags and does nothing else. Position and
velocity are never modified, so:

- the character does not walk, fall, jump, or slide;
- yaw and pitch **are** applied, because they are copied straight from the input frame,
  so the character turns with the camera but cannot move;
- sprinting is never granted, so `state.Sprinting` is always `false`;
- gravity, drag, acceleration, step-up, and the velocity cutoff are all specified but
  unexercised.

The collision core underneath is complete and tested in isolation; it is simply never
called. See "Collision is implemented but not connected" below.

---

## Collision is implemented but not connected to movement

`Collision.moveEntity` performs per-axis clipping, step-up, and penetrating-block
recovery, and a world is registered at startup — but **no code path calls it**. The
motion pipeline that would call it is the stub described above.

Practical effect: collision currently has **zero** influence on anything that happens in
the game. It cannot be exercised by playing; only by calling the module directly.

---

## Combat remains disabled

`CombatConfig.Enabled = false` (`ReplicatedStorage/MinecraftShared/CombatConfig.lua:18`).

The server still creates the `CombatAttack` / `CombatResult` remotes and still handles
attack requests, but every request is answered with
`{ Accepted = false, Reason = "CombatDisabled" }`
(`ServerScriptService/MinecraftServer.server.lua:375`). The client does not send attack
input at all.

`CombatMath` and `RaycastHitbox` remain all-stubs returning `nil` / `false`, which the
callers treat as a reject. Damage, knockback, cooldown, weapon resolution, reach checks,
and line-of-sight are all unexercised. Nothing in combat should be assumed to work.

---

## No Roblox Studio Play test has been performed

This baseline has **not been run in Roblox Studio**, not even once. What has and has not
been verified:

**Verified** — offline, with a standalone Luau interpreter and a hand-written shim for
`Vector3`, `Enum`, and `CFrame`:

- the module require graph loads without error and without cycles;
- state, input, queueing, history, and reconciliation logic;
- the collision core against fixture geometry, including per-axis clipping and step-up;
- structural checks: no duplicate definitions, no unresolved config keys, no dangling
  cross-module calls, every ModuleScript ends with its expected `return`.

**Not verified — assumed, never observed:**

- every Roblox API call actually exists and behaves as assumed (`UserInputService`,
  `RunService`, `workspace.CurrentCamera`, `RaycastParams`, `PlayerGui`, and so on);
- the character rig: R6 vs R15, part names, `HipHeight`, whether `HumanoidRootPart` is
  where the code expects, and the true root-to-feet offset;
- whether an **anchored** root written by both the server and the client produces
  jitter or replication fights — this is the highest-risk untested assumption in the
  networking path;
- `Part.Shape == Enum.PartType.Block`, and whether the authored geometry really is
  axis-aligned, unrotated, and on a 4-stud grid;
- all Studio-only behaviour: remotes, replication order, `task.spawn` timing,
  `Heartbeat` dt, `ScreenGui` rendering.

The shim is a stand-in, not a Roblox emulator. Nothing here should be reported as
"tested in Roblox".
