--!strict
-- Reconcile
-- Client-side reconciliation policy. Pure functions: no Roblox services, no
-- rendering, no networking.
--
-- Timeline model this implements:
--   * A snapshot is the authoritative state at `ServerTick`, after applying
--     every input with Seq <= `LastAppliedInputSeq`.
--   * Inputs with Seq > LastAppliedInputSeq are unacknowledged and are replayed
--     on top of the snapshot, one per simulated tick. Replay is deterministic
--     because it uses the same MovementMath.step as the server.
--   * The whole state is replaced by the authoritative one. Velocity, flags,
--     timers, and health are never ignored because positional error is small.
--   * Visual smoothness is a separate, presentation-only offset that decays;
--     it never feeds back into the simulation state.
--
-- `LastAppliedInputSeq` and `ServerTick` are independent clocks (see
-- MovementConfig): the client's sequence counter advances per predicted step and
-- drifts from the server's simulation tick by design, so comparing the two
-- numerically would reject perfectly valid snapshots. Seq is only ever compared
-- with Seq; ServerTick only with ServerTick.

local MovementConfig = require(script.Parent.MovementConfig)
local MovementState = require(script.Parent.MovementState)
local InputState = require(script.Parent.InputState)
local MovementMath = require(script.Parent.MovementMath)
local Collision = require(script.Parent.Collision)

local Reconcile = {}

export type Snapshot = {
	SchemaVersion: number,
	Generation: number,
	ServerTick: number,
	LastAppliedInputSeq: number,
	-- Visual root-to-feet distance the server measured for this character, in
	-- studs. The client uses this value rather than its own measurement so both
	-- sides place the HumanoidRootPart at exactly the same height.
	RootToFeetOffsetStuds: number,
	Reset: boolean,
	ResetKind: string?,
	Health: number,
	State: MovementState.State,
}

export type Acceptance = "NewGeneration" | "Accept" | "Stale"

local ALLOWED_KEYS: { [any]: boolean } = {
	SchemaVersion = true,
	Generation = true,
	ServerTick = true,
	LastAppliedInputSeq = true,
	RootToFeetOffsetStuds = true,
	Reset = true,
	ResetKind = true,
	Health = true,
	State = true,
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isIntegerInRange(value: any, minimum: number, maximum: number): boolean
	if not isFiniteNumber(value) then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return value >= minimum and value <= maximum
end

function Reconcile.parseSnapshot(raw: any): Snapshot?
	if type(raw) ~= "table" then
		return nil
	end
	for key in pairs(raw) do
		if not ALLOWED_KEYS[key] then
			return nil
		end
	end

	if raw.SchemaVersion ~= MovementConfig.SchemaVersion then
		return nil
	end
	if not isIntegerInRange(raw.Generation, 1, 2147483647) then
		return nil
	end
	if not isIntegerInRange(raw.ServerTick, 0, 2147483647) then
		return nil
	end
	if not isIntegerInRange(raw.LastAppliedInputSeq, 0, 2147483647) then
		return nil
	end
	if not isFiniteNumber(raw.RootToFeetOffsetStuds) then
		return nil
	end
	if raw.RootToFeetOffsetStuds <= 0 or raw.RootToFeetOffsetStuds > MovementConfig.Units.MaxRootToFeetOffsetStuds then
		return nil
	end
	if type(raw.Reset) ~= "boolean" then
		return nil
	end
	if raw.ResetKind ~= nil then
		if type(raw.ResetKind) ~= "string" or #raw.ResetKind > MovementConfig.Network.MaxResetKindLength then
			return nil
		end
		if not raw.Reset then
			return nil
		end
	end
	if not isFiniteNumber(raw.Health) then
		return nil
	end

	local state = MovementState.fromSnapshot(raw.State)
	if state == nil then
		return nil
	end

	-- Envelope and state must describe the same instant. A mismatch means the
	-- payload was assembled incorrectly or tampered with.
	if state.Generation ~= raw.Generation then
		return nil
	end
	if state.ServerTick ~= raw.ServerTick then
		return nil
	end
	if state.LastAppliedInputSeq ~= raw.LastAppliedInputSeq then
		return nil
	end
	if state.Health ~= raw.Health then
		return nil
	end

	return {
		SchemaVersion = raw.SchemaVersion,
		Generation = raw.Generation,
		ServerTick = raw.ServerTick,
		LastAppliedInputSeq = raw.LastAppliedInputSeq,
		RootToFeetOffsetStuds = raw.RootToFeetOffsetStuds,
		Reset = raw.Reset,
		ResetKind = raw.ResetKind,
		Health = raw.Health,
		State = state,
	}
end

-- Generation is the primary acceptance key. A higher generation is always a
-- reset (spawn/respawn/resync) and must clear all history. A lower generation
-- is a delayed packet from an old character and is always discarded. Within a
-- generation, simulation time must strictly advance; a Reset is accepted only
-- because the server emits it at the current (newer) ServerTick.
function Reconcile.shouldAccept(snapshot: Snapshot, currentGeneration: number, lastSnapshotTick: number): Acceptance
	if snapshot.Generation > currentGeneration then
		return "NewGeneration"
	end
	if snapshot.Generation < currentGeneration then
		return "Stale"
	end
	if snapshot.ServerTick <= lastSnapshotTick then
		return "Stale"
	end
	return "Accept"
end

function Reconcile.canPredict(pendingCount: number): boolean
	return pendingCount < MovementConfig.Prediction.MaxPendingInputs
end

-- Replays every pending frame the snapshot has not acknowledged, in order, on
-- top of the authoritative state. Replay stops at the first sequence gap so a
-- predicted state can never be built from non-contiguous history.
function Reconcile.apply(
	authoritative: MovementState.State,
	pending: { InputState.InputFrame },
	world: Collision.CollisionWorld
): (MovementState.State, { InputState.InputFrame }, number)
	local remaining: { InputState.InputFrame } = {}
	local replayed = 0
	local state = MovementState.clone(authoritative)
	local stopped = false

	for _, frame in ipairs(pending) do
		if frame.Generation ~= authoritative.Generation or frame.Seq <= authoritative.LastAppliedInputSeq then
			-- Already acknowledged (or from another generation): drop it.
			continue
		end
		if stopped or frame.Seq ~= state.LastAppliedInputSeq + 1 then
			stopped = true
			table.insert(remaining, frame)
			continue
		end
		replayed += 1
		state = MovementMath.step(state, frame, world, state.ServerTick + 1)
		table.insert(remaining, frame)
	end

	return state, remaining, replayed
end

-- Presentation-only correction. `previous` is what the player currently sees;
-- `updated` is the new authoritative+replay prediction. Adding the delta keeps
-- the visual where it was while the simulation has already moved on.
function Reconcile.computeOffset(
	previous: MovementState.State?,
	updated: MovementState.State,
	offset: Vector3,
	snapDistance: number
): (Vector3, boolean)
	if previous == nil then
		return Vector3.zero, true
	end
	local delta = previous.Position - updated.Position
	if delta.Magnitude > snapDistance then
		return Vector3.zero, true
	end
	local combined = offset + delta
	if combined.Magnitude > snapDistance then
		return Vector3.zero, true
	end
	return combined, false
end

return Reconcile
