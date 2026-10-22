--!strict
-- CombatConfig
-- Every numeric constant used by combat and combat networking.
--
-- Target: Minecraft Java Edition 1.9 combat (attack cooldown system).
-- NOT 1.8.9 combat (no spam clicking, no cooldown-free damage).
--
-- Values marked [VERIFY] should be double-checked against a 1.9 decompile
-- before the detailed implementation is finalized.

local CombatConfig = {}

CombatConfig.Target = "JavaEdition_1.9"

-- Foundation stage: combat is intentionally disabled. Both entry scripts gate
-- on this flag; the RemoteEvents still exist so names and Explorer layout are
-- unchanged.
CombatConfig.Enabled = false

CombatConfig.Health = {
	MaxHealth = 20, -- 10 hearts
}

CombatConfig.Attack = {
	TicksPerSecond = 20,
	CooldownAdjustTicks = 0.5, -- partial tick added when computing cooldown strength
	MinDamageScale = 0.2, -- damage *= MinDamageScale + strength^2 * DamageScaleRange
	DamageScaleRange = 0.8,
}

CombatConfig.Critical = {
	MinCooldownStrength = 0.9,
	DamageMultiplier = 1.5,
	RequiresFalling = true,
	RequiresNotOnGround = true,
	ForbidSprinting = true, -- 1.9: sprinting prevents critical hits [VERIFY]
	ForbidInLiquid = true,
	ForbidOnClimbable = true,
}

CombatConfig.Sweep = {
	EnabledForSwordsOnly = true,
	MinCooldownStrength = 0.9,
	ExtraBoxX = 1.0, -- blocks
	ExtraBoxY = 0.25,
	ExtraBoxZ = 1.0,
	DamageBase = 1.0,
}

CombatConfig.Reach = {
	SurvivalReach = 3.0, -- blocks
	TargetHitboxMargin = 0.1, -- blocks
}

CombatConfig.Invulnerability = {
	HurtResistantTicks = 20,
	FullDamageWindowTicks = 10, -- during the first half, only damage above the last hit applies
}

CombatConfig.Knockback = {
	BaseStrength = 0.4,
	DragDivisor = 2.0, -- previous velocity is divided by this before knockback is added
	VerticalCap = 0.4,
	PerLevel = 0.5,
	SprintBonusLevels = 1,
	SprintMinCooldownStrength = 0.9, -- 1.9: sprint knockback needs a charged attack [VERIFY]
}

CombatConfig.DefaultWeaponId = "Fist"

-- Damage is the attribute total (includes the base 1 point). [VERIFY all rows]
CombatConfig.Weapons = {
	Fist = { Damage = 1, AttackSpeed = 4.0, IsSword = false },

	WoodenSword = { Damage = 4, AttackSpeed = 1.6, IsSword = true },
	GoldenSword = { Damage = 4, AttackSpeed = 1.6, IsSword = true },
	StoneSword = { Damage = 5, AttackSpeed = 1.6, IsSword = true },
	IronSword = { Damage = 6, AttackSpeed = 1.6, IsSword = true },
	DiamondSword = { Damage = 7, AttackSpeed = 1.6, IsSword = true },

	WoodenAxe = { Damage = 7, AttackSpeed = 0.8, IsSword = false },
	GoldenAxe = { Damage = 7, AttackSpeed = 1.0, IsSword = false },
	StoneAxe = { Damage = 9, AttackSpeed = 0.8, IsSword = false },
	IronAxe = { Damage = 9, AttackSpeed = 0.9, IsSword = false },
	DiamondAxe = { Damage = 9, AttackSpeed = 1.0, IsSword = false },
}

CombatConfig.Server = {
	MaxAttackTickSkew = 10, -- allowed |claimed tick - server-known attacker tick|
	MaxAttackRequestsPerSecond = 20,
	ReachSlack = 0.3, -- NOT vanilla: latency tolerance added to SurvivalReach
	InitialTicksSinceAttack = 1000, -- start with a fully charged attack
	InitialTicksSinceHurt = 1000, -- start with no invulnerability
}

CombatConfig.Remotes = {
	Attack = "CombatAttack", -- client -> server: { TargetUserId, Tick }
	Result = "CombatResult", -- server -> attacker: { Accepted, Reason }
}

return CombatConfig
