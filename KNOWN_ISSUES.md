# Known issues

Recorded deliberately. This revision fixes three baseline defects and leaves the rest
untouched: **movement is still stubbed, combat is still disabled, and nothing here has
been run in Roblox Studio by the author.** Read this before testing so an expected
inert result is not mistaken for a bug.

References use module and function names rather than line numbers, which drift.

---

## Resolved in this revision

### F1 — `Seq` was compared against `ServerTick`

Fixed. `MovementState.fromSnapshot`, `MovementState.isPlausible` and
`Reconcile.parseSnapshot` no longer reject a state because
`LastAppliedInputSeq > ServerTick`.

The invariant now enforced is the one the two counters actually satisfy:

- `Seq` / `LastAppliedInputSeq` order, de-duplicate, acknowledge, and replay input.
  They are validated only as integers in `[0, 2^31-1]` and are compared only with each
  other.
- `ServerTick` is server simulation time. It is validated as an integer and compared
  only with simulation time (monotonic step, snapshot ordering).
- A state whose acknowledged sequence is far above or below its tick is valid. The
  client predicts at its own rate and the server drops catch-up backlog under load, so
  the counters drift by design.

Regression coverage: foundation tests assert that a state and a snapshot with
`LastAppliedInputSeq = ServerTick + 5000` (and the reverse) are accepted and plausible,
while negative and fractional sequences are still rejected.

### F5 — the collision world was built once and never rebuilt

Fixed for the running game. Both entry points now call `CollisionAdapter.watch` instead
of a one-shot `fromWorkspace`, and read `collision.World` at use time.

- A missing `workspace.World` at startup produces an empty world **temporarily**, not
  permanently: the adapter watches `workspace.ChildAdded` / `ChildRemoved` and rebuilds
  when the folder appears, disappears, is renamed, or is reparented.
- Changes inside the folder (`DescendantAdded` / `DescendantRemoving`) and geometry
  property changes on registered parts (`Size`, `Anchored`, `CanCollide`, `Shape`, and
  `CFrame` while anchored) schedule a rebuild.
- Every rebuild builds a **new** `Collision.World` and swaps the reference, so no box is
  ever registered twice and a partially built world can never be observed.
- Rebuilds are coalesced by `MovementConfig.Collision.RebuildDebounceSeconds` (0.25 s).

Remaining limitations, by design:

- The world is still **static geometry only**. Entity-vs-entity collision and moving
  solids are not part of this design.
- The server and the client each maintain their own world. During the debounce window
  after a geometry change they can briefly disagree; the server is authoritative and
  reconciliation corrects the client, and movement is not connected yet, so nothing
  observable depends on it today.
- A part whose `CFrame` changes is watched only while it is anchored. Unanchored parts
  are rejected anyway, so watching their per-physics-step `CFrame` would only churn
  rebuilds.
- Rebuilds are full rescans. There is no incremental add/remove path and no spatial
  index reuse; with `MaxBoxes = 8192` a rescan is bounded, but it is O(folder).

### Hard-coded `RootToFeetOffsetStuds = 3`

Fixed. `MovementConfig.Units.RootToFeetOffsetStuds` no longer exists. The offset is
resolved at runtime by the new shared module `RigOffset`:

- `RigOffset.fromGeometry(HipHeight, rootSizeY)` = `HipHeight + rootSizeY / 2`, the
  distance Roblox keeps between a humanoid's feet and the centre of its root part.
- `RigOffset.measure(character)` reads the live `Humanoid` and `HumanoidRootPart`; the
  server calls it once per session. The server publishes the result in every snapshot
  (`RootToFeetOffsetStuds`, schema 3), and the client presents with that value, so a
  difference between the two copies of the rig cannot cause a height fight.
- The client still measures its own rig once per character, for diagnostics only: a
  difference of more than 0.001 studs logs one warning and the server value is used.
- The simulation stays in **blocks**; only the Roblox boundary
  (`MovementMath.feetBlocksToRootStuds`, `rootStudsToFeetBlocks`, `toRootCFrame`) and
  the one-time spawn conversion consume studs.
- The Minecraft hitbox (`MovementConfig.Hitbox`: 0.6 × 1.8, 1.65 sneaking) is unchanged
  and never derived from rig size.

Remaining limitations:

- The offset is measured **once per character**. If a script changes
  `Humanoid.HipHeight` or the root part's size mid-session, the offset is not
  re-measured until the character respawns. This is deliberate: a mid-session change
  would also require a reset to avoid a visible jump.
- A rig that cannot be measured — no `Humanoid`, no `HumanoidRootPart`, non-finite or
  non-positive `HipHeight` (R6 reports 0 and is not described by the HipHeight rule), a
  non-positive root height, or a result above
  `Units.MaxRootToFeetOffsetStuds` — uses the documented fallback
  `Units.RootToFeetOffsetStudsFallback = 3` and logs a warning with the reason. For a
  default R6 rig that fallback is also the geometrically correct value (legs 2 + half
  torso 1); for other unmeasurable rigs it is only a safe default, not a measurement.
- Client-side rig mutation (a local scale or HipHeight change that never replicates)
  affects only the warning, not placement: presentation always follows the server's
  snapshot value.

---

## F2 — No per-block slipperiness metadata channel

Unchanged. Minecraft applies ground friction by multiplying a global drag factor by the
slipperiness of the block beneath the entity: 0.6 for normal blocks, 0.8 for ice, 0.98
for packed ice, and so on. The collision world stores **only solid geometry** — there is
no channel through which a block can report a friction value.

As a result:

- `MovementConfig.Physics.SlipperinessDefault = 0.6` is a **constant stand-in**, not a
  lookup.
- The collision core has no metadata callback, no material tag, and no way to ask "what
  is under this box". `Collision.moveEntity` returns `OnGround` and per-axis collision
  flags, and nothing else.
- Ice, packed ice, frosted ice, slime, and soul sand therefore cannot behave correctly
  once movement is written. They will behave like stone.

This is a missing data channel, not a missing formula: the drag maths is specified, the
input to it is not available.

---

## Oversized parts are rejected, not clipped (authoring constraint)

Each registered box is decomposed into grid cells. `Collision.MaxCellsPerBox = 4096`
caps that decomposition. A part over the cap is now rejected **before** registration
with `Category = "Oversized"` and a reason that states the measured cell count, the cap,
and the part's full name. It is counted in `Report.Oversized`, listed in
`Report.Unsupported`, and warned about once per rebuild.

It is not clipped, split, or silently dropped, and it no longer aborts the rebuild: the
whole world is still built from every part that fits. `Collision.addBox` still raises if
called directly with such a box, because that is a programming error rather than an
authoring one.

At 1 block = 1 cell, a merged part larger than roughly 16×16×16 blocks cannot be
registered. Large solid regions must be split into smaller parts.

---

## Movement remains stubbed

`MovementMath.PHYSICS_IMPLEMENTED = false`.

`stepPlayerTick` clears the per-tick collision flags and does nothing else. Position and
velocity are never modified, so:

- the character does not walk, fall, jump, or slide;
- yaw and pitch **are** applied, because they are copied straight from the input frame,
  so the character turns with the camera but cannot move;
- sprinting is never granted, so `state.Sprinting` is always `false`;
- gravity, drag, acceleration, step-up, and the velocity cutoff are all specified but
  unexercised.

No sprinting, jumping, gravity, or special-block behaviour was added in this revision.

---

## Collision is implemented but not connected to movement

`Collision.moveEntity` performs per-axis clipping, step-up, and penetrating-block
recovery, and a watched world is maintained — but **no code path calls it**. The motion
pipeline that would call it is the stub described above.

Practical effect: collision still has **zero** influence on anything that happens in the
game. It cannot be exercised by playing; only by calling the module directly.

---

## Combat remains disabled

`CombatConfig.Enabled = false`.

The server still creates the `CombatAttack` / `CombatResult` remotes and still handles
attack requests, but every request is answered with
`{ Accepted = false, Reason = "CombatDisabled" }`. The client does not send attack input
at all.

`CombatMath` and `RaycastHitbox` remain all-stubs returning `nil` / `false`, which the
callers treat as a reject. Damage, knockback, cooldown, weapon resolution, reach checks,
and line-of-sight are all unexercised.

---

## No Roblox Studio Play test of this revision

**This revision has not been run in Roblox Studio.** No claim of Studio behaviour is
made for the three fixes above.

What was verified, offline, with the standalone Luau interpreter and the hand-written
shim for `Vector3`, `Enum`, and `CFrame`:

- foundation suite: **437 checks, 0 failures**;
- collision suite: **209 checks, 0 failures**;
- every install file compiles (`luau-compile`) and every module ends with its expected
  top-level `return`;
- the cross-file consistency scan resolves every `Config.*` key, has no duplicate
  definitions, and resolves every cross-module call;
- the rig-offset rule and its fallbacks, the removal of the cross-clock comparisons, and
  the oversized-rejection path are covered by the suites above.

Still unverified, and therefore assumed:

- every Roblox API used by the new watch path actually behaves as assumed:
  `DescendantAdded` / `DescendantRemoving` / `AncestryChanged` /
  `GetPropertyChangedSignal` cadence and ordering during bulk insertion;
- whether `Humanoid.HipHeight` is populated on both server and client at
  `CharacterAdded` (the fallback covers the case where it is not, but the warning itself
  is untested);
- whether an anchored root written by both the server and the client produces jitter or
  replication fights — unchanged from the previous revision and still the highest-risk
  assumption in the networking path;
- rebuild cost on a realistic `workspace.World` (the debounce bounds frequency, not
  duration);
- Studio-only behaviour: remotes, replication order, `task.spawn` / `task.delay` timing,
  `Heartbeat` dt, `ScreenGui` rendering.

Earlier installation of the previous revision was verified in Studio by the consumer of
this repository (16 files, SHA-256 match, no Play errors, four remotes created, character
frozen as expected, `workspace.World` absent so the world was empty, measured
root-to-feet offset 3.299 studs). That verification covers the *previous* file set only.
