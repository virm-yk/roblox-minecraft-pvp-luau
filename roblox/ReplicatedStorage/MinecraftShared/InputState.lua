--!strict
-- InputState
-- Pure data definition, construction, processing, and validation for one tick of
-- player input. No Roblox input APIs here (InputController polls those) and no
-- movement logic.
--
-- Sequence model:
--   Generation : the session generation this input belongs to. The server rejects
--                frames whose generation is not its current session generation.
--   Seq        : per-generation monotonic input sequence, 1..2^31-1. This is NOT
--                simulation time. It orders, de-duplicates, and acknowledges input.
--   ClientTick : the client's own prediction index when it applied this input.
--                Informational only (diagnostics and, later, lag compensation).
--                Never used as authoritative time.
--
-- Server-internal frames (idle / starved) may reuse a Seq; they never advance
-- the acknowledged sequence.
--
-- Axis model (schema 2) - the single most important thing in this file:
--   RawInput holds raw key state (booleans). It is never sent anywhere.
--   InputFrame.MoveForward/MoveStrafe hold the PROCESSED axes, i.e. exactly the
--   values 1.9 hands to the movement code:
--     * opposing keys cancel before any scaling (1.9 sums +1/-1);
--     * the sneak multiplier (Input.SneakScale) is applied ONCE, at input
--       collection, mirroring MovementInputFromOptions.updatePlayerMoveState;
--     * the 0.98 per-tick input damping is NOT applied here. It belongs to the
--       movement step (EntityLivingBase:2344) and must be applied exactly once
--       there (see MovementMath);
--     * axes are NOT normalized. W+D keeps unit axes and a sqrt(2) magnitude;
--       moveFlying normalization belongs to the movement stage.
--
--   Sprint is a REQUEST (the sprint key being held). Neither Sprint nor any
--   grounded state is authoritative: the server decides sprint eligibility in
--   the movement stage and never copies the request into MovementState.Sprinting.

local MovementConfig = require(script.Parent.MovementConfig)

local InputState = {}

local MAX_INT = 2147483647
local MAX_FIELD_COUNT = MovementConfig.Network.MaxInputFields

export type InputFrame = {
	Generation: number,
	Seq: number,
	ClientTick: number,
	MoveForward: number, -- processed: -MaxAxis .. MaxAxis, sneak-scaled once
	MoveStrafe: number, -- processed: positive = left, sneak-scaled once
	Jump: boolean, -- held state, not an edge
	Sprint: boolean, -- request only; never authoritative
	Sneak: boolean, -- held state
	Yaw: number, -- degrees, wrapped to (-180, 180]
	Pitch: number, -- degrees, clamped to +-PitchLimitDegrees (positive = down)
}

-- Raw key state as polled from the platform. Kept separate from InputFrame on
-- purpose: nothing derived from it is authoritative until `process` runs.
export type RawInput = {
	Forward: boolean,
	Back: boolean,
	Left: boolean,
	Right: boolean,
	Jump: boolean,
	Sneak: boolean,
	Sprint: boolean,
	Suppressed: boolean, -- typing in a TextBox, or the window is unfocused
	SuppressedReason: string?, -- "Typing" | "Unfocused" | nil (diagnostics only)
}

-- Keys accepted on the wire. "Kind" is part of the envelope, not the frame type.
local ALLOWED_KEYS: { [any]: boolean } = {
	Kind = true,
	Generation = true,
	Seq = true,
	ClientTick = true,
	MoveForward = true,
	MoveStrafe = true,
	Jump = true,
	Sprint = true,
	Sneak = true,
	Yaw = true,
	Pitch = true,
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Rejects NaN, infinities, fractional values, and out-of-range integers.
local function isIntegerInRange(value: any, minimum: number, maximum: number): boolean
	if not isFiniteNumber(value) then
		return false
	end
	if value % 1 ~= 0 then
		return false
	end
	return value >= minimum and value <= maximum
end

local function clampPitch(value: number): number
	return math.clamp(value, -MovementConfig.Input.PitchLimitDegrees, MovementConfig.Input.PitchLimitDegrees)
end

function InputState.wrapYaw(value: number): number
	local wrapped = value % 360
	if wrapped >= 180 then
		wrapped -= 360
	elseif wrapped < -180 then
		wrapped += 360
	end
	return wrapped
end

function InputState.neutral(generation: number, seq: number, clientTick: number, yaw: number, pitch: number): InputFrame
	return {
		Generation = generation,
		Seq = seq,
		ClientTick = clientTick,
		MoveForward = 0,
		MoveStrafe = 0,
		Jump = false,
		Sprint = false,
		Sneak = false,
		Yaw = InputState.wrapYaw(yaw),
		Pitch = clampPitch(pitch),
	}
end

function InputState.clone(frame: InputFrame): InputFrame
	return {
		Generation = frame.Generation,
		Seq = frame.Seq,
		ClientTick = frame.ClientTick,
		MoveForward = frame.MoveForward,
		MoveStrafe = frame.MoveStrafe,
		Jump = frame.Jump,
		Sprint = frame.Sprint,
		Sneak = frame.Sneak,
		Yaw = frame.Yaw,
		Pitch = frame.Pitch,
	}
end

-- Server-internal substitute for a tick with no fresh input. It repeats only
-- orientation and the sneak flag, never axes/jump/sprint, so a missing packet
-- can never keep a player walking forward. Seq is unchanged, so this frame
-- does not acknowledge anything.
function InputState.starved(last: InputFrame): InputFrame
	return {
		Generation = last.Generation,
		Seq = last.Seq,
		ClientTick = last.ClientTick,
		MoveForward = 0,
		MoveStrafe = 0,
		Jump = false,
		Sprint = false,
		Sneak = last.Sneak,
		Yaw = last.Yaw,
		Pitch = last.Pitch,
	}
end

-- First-tick frame before any input has ever been accepted for this generation.
function InputState.idle(generation: number, yaw: number, pitch: number): InputFrame
	return InputState.neutral(generation, 0, 0, yaw, pitch)
end

-- ===== Raw key state =====

function InputState.newRaw(): RawInput
	return {
		Forward = false,
		Back = false,
		Left = false,
		Right = false,
		Jump = false,
		Sneak = false,
		Sprint = false,
		Suppressed = false,
		SuppressedReason = nil,
	}
end

-- Drops every held key without touching the suppression flags. This is the
-- equivalent of KeyBinding.unPressAllKeys(): after focus loss, teardown, or a
-- return from typing, nothing may stay latched.
function InputState.clearRaw(raw: RawInput)
	raw.Forward = false
	raw.Back = false
	raw.Left = false
	raw.Right = false
	raw.Jump = false
	raw.Sneak = false
	raw.Sprint = false
end

-- Enters/leaves the suppressed state. Entering always clears held keys.
function InputState.suppress(raw: RawInput, reason: string?)
	if reason ~= nil then
		InputState.clearRaw(raw)
	end
	raw.Suppressed = reason ~= nil
	raw.SuppressedReason = reason
end

-- Pre-scale integer axes, for diagnostics only. Forward +1 = W, strafe +1 = A.
function InputState.rawAxes(raw: RawInput): (number, number)
	if raw.Suppressed then
		return 0, 0
	end
	local forward = (if raw.Forward then 1 else 0) - (if raw.Back then 1 else 0)
	local strafe = (if raw.Left then 1 else 0) - (if raw.Right then 1 else 0)
	return forward, strafe
end

-- ===== Raw -> processed =====
--
-- The one and only place the sneak multiplier is applied. Opposing keys cancel
-- first, exactly like 1.9's +1/-1 accumulation, so W+S is exactly 0 even while
-- sneaking. Jump/sneak/sprint are passed through as held states; a suppressed
-- frame carries no input at all but still carries the look direction.

function InputState.process(
	raw: RawInput,
	generation: number,
	seq: number,
	clientTick: number,
	yaw: number,
	pitch: number
): InputFrame
	local forward = 0
	local strafe = 0
	local jump = false
	local sneak = false
	local sprint = false

	if not raw.Suppressed then
		forward = (if raw.Forward then 1 else 0) - (if raw.Back then 1 else 0)
		strafe = (if raw.Left then 1 else 0) - (if raw.Right then 1 else 0)
		jump = raw.Jump
		sneak = raw.Sneak
		sprint = raw.Sprint
	end

	-- Applied once, at collection, after cancellation - never again downstream.
	local scale = if sneak then MovementConfig.Input.SneakScale else 1

	return {
		Generation = generation,
		Seq = seq,
		ClientTick = clientTick,
		MoveForward = forward * scale,
		MoveStrafe = strafe * scale,
		Jump = jump,
		Sprint = sprint,
		Sneak = sneak,
		Yaw = InputState.wrapYaw(yaw),
		Pitch = clampPitch(pitch),
	}
end

-- ===== Untrusted wire validation =====

-- Validates and normalises an untrusted frame from the network.
-- Returns nil for anything malformed; never throws.
function InputState.sanitize(raw: any): InputFrame?
	if type(raw) ~= "table" then
		return nil
	end
	if raw.Kind ~= nil and raw.Kind ~= "Input" then
		return nil
	end

	local fieldCount = 0
	for key in pairs(raw) do
		if not ALLOWED_KEYS[key] then
			return nil
		end
		fieldCount += 1
	end
	if fieldCount > MAX_FIELD_COUNT then
		return nil
	end

	if not isIntegerInRange(raw.Generation, 1, MAX_INT) then
		return nil
	end
	if not isIntegerInRange(raw.Seq, 1, MAX_INT) then
		return nil
	end
	if not isIntegerInRange(raw.ClientTick, 0, MAX_INT) then
		return nil
	end
	if not isFiniteNumber(raw.MoveForward) or not isFiniteNumber(raw.MoveStrafe) then
		return nil
	end
	if not isFiniteNumber(raw.Yaw) or not isFiniteNumber(raw.Pitch) then
		return nil
	end
	if type(raw.Jump) ~= "boolean" or type(raw.Sprint) ~= "boolean" or type(raw.Sneak) ~= "boolean" then
		return nil
	end

	-- Axes arrive already sneak-scaled. The server therefore CLAMPS instead of
	-- scaling again: an honest frame is unchanged, and a client that claims to
	-- be sneaking cannot smuggle full-speed axes past the multiplier.
	local axisLimit = if raw.Sneak then MovementConfig.Input.SneakScale else MovementConfig.Input.MaxAxis

	return {
		Generation = raw.Generation,
		Seq = raw.Seq,
		ClientTick = raw.ClientTick,
		MoveForward = math.clamp(raw.MoveForward, -axisLimit, axisLimit),
		MoveStrafe = math.clamp(raw.MoveStrafe, -axisLimit, axisLimit),
		Jump = raw.Jump,
		Sprint = raw.Sprint,
		Sneak = raw.Sneak,
		Yaw = InputState.wrapYaw(raw.Yaw),
		Pitch = clampPitch(raw.Pitch),
	}
end

return InputState
