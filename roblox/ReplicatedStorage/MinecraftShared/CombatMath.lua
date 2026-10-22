--!strict
-- CombatMath
-- Pure Minecraft 1.9 combat formulas. No networking, no Roblox instances,
-- no world queries. All distances in BLOCKS, velocities in BLOCKS PER TICK.
--
-- STATUS: skeleton. Every function returns nil ("not implemented"); callers
-- MUST treat nil as "reject". Constants come from CombatConfig only.

local CombatConfig = require(script.Parent.CombatConfig)
local MovementState = require(script.Parent.MovementState)

local CombatMath = {}

export type CriticalContext = {
	CooldownStrength: number,
	Attacker: MovementState.State,
}

export type KnockbackContext = {
	AttackerYaw: number,
	CooldownStrength: number,
	AttackerSprinting: boolean,
	TargetVelocity: Vector3,
}

-- Ticks needed for a full cooldown at the given attack speed.
function CombatMath.getAttackCooldownTicks(_attackSpeed: number): number?
	return nil -- TODO: (1 / attackSpeed) * CombatConfig.Attack.TicksPerSecond
end

-- 0..1 charge of the attack cooldown.
function CombatMath.getCooldownStrength(_ticksSinceLastAttack: number, _attackSpeed: number): number?
	return nil -- TODO: uses CombatConfig.Attack.CooldownAdjustTicks
end

-- Applies the cooldown damage scaling.
function CombatMath.scaleDamage(_baseDamage: number, _cooldownStrength: number): number?
	return nil -- TODO: uses MinDamageScale / DamageScaleRange
end

function CombatMath.isCritical(_context: CriticalContext): boolean?
	return nil -- TODO: uses CombatConfig.Critical
end

-- Invulnerability window check (hurt-resistance system).
function CombatMath.canDamage(_ticksSinceLastHurt: number, _lastDamage: number, _newDamage: number): boolean?
	return nil -- TODO: uses CombatConfig.Invulnerability
end

-- Velocity to ADD to the target (blocks/tick), already including the drag of its old velocity.
function CombatMath.computeKnockback(_context: KnockbackContext): Vector3?
	return nil -- TODO: uses CombatConfig.Knockback
end

return CombatMath
