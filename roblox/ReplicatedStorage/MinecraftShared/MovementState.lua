--!strict
-- MovementState
-- Pure data container for one player's movement simulation state.
-- Positions are in BLOCKS (feet, bottom-center). Velocities are in BLOCKS PER TICK.
-- No simulation logic lives here.
--
-- Identity and time:
--   Generation          : server-owned session generation. Increments on spawn,
--                         respawn, and every authoritative reset. Delayed packets
--                         from an older generation can never affect a newer one.
--   ServerTick          : server-owned simulation time. Advanced by exactly one
--                         per movement step.
--   LastAppliedInputSeq : highest client input sequence whose effects are included
--                         in this state. Advanced only when an input is consumed.
--
-- The snapshot shape is the state shape; every field is remote-safe.

local MovementConfig = require(script.Parent.MovementConfig)

local MovementState = {}

local MAX_INT = 2147483647
local MAX_HEALTH = 20 -- 1.9 player max; keep in sync with CombatConfig.Health.MaxHealth
local MAX_LAST_DAMAGE = 1024
local MAX_FALL_DISTANCE = 4096
local MAX_TICKS_SINCE_ATTACK = 1000000000
local MAX_WEAPON_ID_LENGTH = 32

export type State = {
	SchemaVersion: number,
	Generation: number,
	ServerTick: number,
	LastAppliedInputSeq: number,

	Position: Vector3, -- blocks, feet bottom-center
	Velocity: Vector3, -- blocks/tick
	Yaw: number, -- degrees, 0 faces +Z, forward = (-sin(yaw), 0, cos(yaw))
	Pitch: number, -- degrees, positive looks down, clamped +-90

	OnGround: boolean,
	CollidedHorizontally: boolean,
	CollidedVertically: boolean,
	CollidedX: boolean,
	CollidedY: boolean,
	CollidedZ: boolean,
	StepUsed: boolean,

	Sprinting: boolean,
	Sneaking: boolean,
	JumpTicks: number, -- 0..MovementConfig.Physics.JumpTicks
	FallDistance: number,

	InWater: boolean,
	InLava: boolean,
	OnClimbable: boolean,
	InWeb: boolean,

	Health: number,
	HurtResistantTime: number, -- 0..20
	LastDamage: number,
	TicksSinceLastAttack: number,
	AttackWeaponId: string,
}

local ALLOWED_KEYS: { [any]: boolean } = {
	SchemaVersion = true,
	Generation = true,
	ServerTick = true,
	LastAppliedInputSeq = true,
	Position = true,
	Velocity = true,
	Yaw = true,
	Pitch = true,
	OnGround = true,
	CollidedHorizontally = true,
	CollidedVertically = true,
	CollidedX = true,
	CollidedY = true,
	CollidedZ = true,
	StepUsed = true,
	Sprinting = true,
	Sneaking = true,
	JumpTicks = true,
	FallDistance = true,
	InWater = true,
	InLava = true,
	OnClimbable = true,
	InWeb = true,
	Health = true,
	HurtResistantTime = true,
	LastDamage = true,
	TicksSinceLastAttack = true,
	AttackWeaponId = true,
}

local BOOLEAN_KEYS = {
	"OnGround",
	"CollidedHorizontally",
	"CollidedVertically",
	"CollidedX",
	"CollidedY",
	"CollidedZ",
	"StepUsed",
	"Sprinting",
	"Sneaking",
	"InWater",
	"InLava",
	"OnClimbable",
	"InWeb",
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

local function isFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

-- Full state reset. Every transient field is written here, so a respawn can
-- never inherit velocity, timers, flags, or fluid state from the old body.
function MovementState.spawn(
	position: Vector3,
	generation: number,
	serverTick: number,
	health: number,
	weaponId: string
): State
	return {
		SchemaVersion = MovementConfig.SchemaVersion,
		Generation = generation,
		ServerTick = serverTick,
		LastAppliedInputSeq = 0,

		Position = position,
		Velocity = Vector3.zero,
		Yaw = 0,
		Pitch = 0,

		OnGround = false,
		CollidedHorizontally = false,
		CollidedVertically = false,
		CollidedX = false,
		CollidedY = false,
		CollidedZ = false,
		StepUsed = false,

		Sprinting = false,
		Sneaking = false,
		JumpTicks = 0,
		FallDistance = 0,

		InWater = false,
		InLava = false,
		OnClimbable = false,
		InWeb = false,

		Health = health,
		HurtResistantTime = 0,
		LastDamage = 0,
		TicksSinceLastAttack = 0,
		AttackWeaponId = weaponId,
	}
end

-- Explicit copy. This MUST list every field; tests assert that the key set of
-- clone(spawn(...)) equals the key set of spawn(...).
function MovementState.clone(state: State): State
	return {
		SchemaVersion = state.SchemaVersion,
		Generation = state.Generation,
		ServerTick = state.ServerTick,
		LastAppliedInputSeq = state.LastAppliedInputSeq,

		Position = state.Position,
		Velocity = state.Velocity,
		Yaw = state.Yaw,
		Pitch = state.Pitch,

		OnGround = state.OnGround,
		CollidedHorizontally = state.CollidedHorizontally,
		CollidedVertically = state.CollidedVertically,
		CollidedX = state.CollidedX,
		CollidedY = state.CollidedY,
		CollidedZ = state.CollidedZ,
		StepUsed = state.StepUsed,

		Sprinting = state.Sprinting,
		Sneaking = state.Sneaking,
		JumpTicks = state.JumpTicks,
		FallDistance = state.FallDistance,

		InWater = state.InWater,
		InLava = state.InLava,
		OnClimbable = state.OnClimbable,
		InWeb = state.InWeb,

		Health = state.Health,
		HurtResistantTime = state.HurtResistantTime,
		LastDamage = state.LastDamage,
		TicksSinceLastAttack = state.TicksSinceLastAttack,
		AttackWeaponId = state.AttackWeaponId,
	}
end

function MovementState.toSnapshot(state: State): State
	return MovementState.clone(state)
end

-- Validates an untrusted snapshot state. Returns nil if malformed or implausible.
function MovementState.fromSnapshot(raw: any): State?
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
	if not isIntegerInRange(raw.Generation, 1, MAX_INT) then
		return nil
	end
	if not isIntegerInRange(raw.ServerTick, 0, MAX_INT) then
		return nil
	end
	if not isIntegerInRange(raw.LastAppliedInputSeq, 0, MAX_INT) then
		return nil
	end
	if raw.LastAppliedInputSeq > raw.ServerTick then
		return nil
	end

	if not isFiniteVector(raw.Position) or not isFiniteVector(raw.Velocity) then
		return nil
	end
	if not isFiniteNumber(raw.Yaw) or not isFiniteNumber(raw.Pitch) then
		return nil
	end
	if math.abs(raw.Pitch) > MovementConfig.Input.PitchLimitDegrees + 0.0001 then
		return nil
	end

	for _, key in ipairs(BOOLEAN_KEYS) do
		if type(raw[key]) ~= "boolean" then
			return nil
		end
	end

	if not isIntegerInRange(raw.JumpTicks, 0, MovementConfig.Physics.JumpTicks) then
		return nil
	end
	if not isFiniteNumber(raw.FallDistance) then
		return nil
	end
	if raw.FallDistance < 0 or raw.FallDistance > MAX_FALL_DISTANCE then
		return nil
	end

	if not isFiniteNumber(raw.Health) or raw.Health < 0 or raw.Health > MAX_HEALTH then
		return nil
	end
	if not isIntegerInRange(raw.HurtResistantTime, 0, 20) then
		return nil
	end
	if not isFiniteNumber(raw.LastDamage) or raw.LastDamage < 0 or raw.LastDamage > MAX_LAST_DAMAGE then
		return nil
	end
	if not isIntegerInRange(raw.TicksSinceLastAttack, 0, MAX_TICKS_SINCE_ATTACK) then
		return nil
	end
	if type(raw.AttackWeaponId) ~= "string" or #raw.AttackWeaponId > MAX_WEAPON_ID_LENGTH then
		return nil
	end

	local state = MovementState.clone(raw :: State)
	if not MovementState.isPlausible(state) then
		return nil
	end
	return state
end

-- Plausibility bound used by the server after every step and by the client
-- when accepting a snapshot. This is a sanity/anti-corruption check, not a
-- substitute for the movement rules.
function MovementState.isPlausible(state: State): boolean
	local limits = MovementConfig.Server
	if not isFiniteVector(state.Position) or not isFiniteVector(state.Velocity) then
		return false
	end
	if state.Velocity.Magnitude > limits.MaxSpeedBlocksPerTick then
		return false
	end
	local p = state.Position
	if math.abs(p.X) > limits.MaxCoordinateBlocks then
		return false
	end
	if math.abs(p.Y) > limits.MaxCoordinateBlocks then
		return false
	end
	if math.abs(p.Z) > limits.MaxCoordinateBlocks then
		return false
	end
	if state.LastAppliedInputSeq > state.ServerTick then
		return false
	end
	if state.JumpTicks < 0 or state.JumpTicks > MovementConfig.Physics.JumpTicks then
		return false
	end
	if state.HurtResistantTime < 0 or state.HurtResistantTime > 20 then
		return false
	end
	if state.Health < 0 or state.Health > MAX_HEALTH then
		return false
	end
	return true
end

return MovementState
