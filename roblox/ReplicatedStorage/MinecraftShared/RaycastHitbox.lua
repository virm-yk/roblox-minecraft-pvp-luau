--!strict
-- RaycastHitbox
-- Attack targeting geometry: eye position, look direction, entity hitbox ray test,
-- and line-of-sight. Used by BOTH client (hit prediction) and server (authority).
-- Knows nothing about damage, cooldowns, or networking.
-- All positions in BLOCKS.
--
-- STATUS: skeleton. Only getEyePosition is implemented; the rest return nil/false
-- ("not implemented"), which callers treat as a rejected attack.

local MovementConfig = require(script.Parent.MovementConfig)
local MovementState = require(script.Parent.MovementState)

local RaycastHitbox = {}

export type Candidate = {
	Id: number,
	Position: Vector3, -- feet, bottom-center (blocks)
	Sneaking: boolean,
}

export type HitResult = {
	TargetId: number,
	Distance: number, -- blocks
	Point: Vector3, -- blocks
}

function RaycastHitbox.getEyePosition(state: MovementState.State): Vector3
	local hitbox = MovementConfig.Hitbox
	local eyeHeight = if state.Sneaking then hitbox.SneakEyeHeight else hitbox.EyeHeight
	return state.Position + Vector3.new(0, eyeHeight, 0)
end

-- Unit look vector from yaw/pitch (degrees), using the MovementMath yaw convention.
function RaycastHitbox.getLookDirection(_yaw: number, _pitch: number): Vector3?
	return nil -- TODO
end

-- Closest candidate whose (margin-expanded) hitbox the ray hits within reach.
function RaycastHitbox.findTarget(
	_origin: Vector3,
	_direction: Vector3,
	_candidates: { Candidate },
	_reach: number
): HitResult?
	return nil -- TODO: uses CombatConfig.Reach.TargetHitboxMargin
end

-- True if no solid world geometry blocks the segment origin -> point.
function RaycastHitbox.hasLineOfSight(_origin: Vector3, _point: Vector3, _ignore: { Instance }): boolean
	return false -- TODO: conservative default rejects the attack
end

return RaycastHitbox
