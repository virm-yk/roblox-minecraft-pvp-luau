--!strict
-- RigOffset
-- Resolves the visual distance between the simulation's feet origin and the
-- centre of the HumanoidRootPart of the rig that is actually present.
--
-- Why this module exists
--   The simulation stores feet position in BLOCKS (see MovementConfig) and the
--   Roblox boundary converts it to a root CFrame. That conversion needs the stud
--   distance between the rig's feet and the centre of its HumanoidRootPart.
--   The distance is a property of the rig, not of Minecraft, so it cannot be a
--   constant: Roblox positions a humanoid's root centre at
--
--       feet + Humanoid.HipHeight + HumanoidRootPart.Size.Y / 2
--
--   and HipHeight is authored per rig and per place. The default R15 value (2
--   with a 2-stud root) is why a hard-coded 3 studs appears to work on one rig
--   and silently misplaces every other one.
--
-- What this does NOT do
--   * It never changes the Minecraft hitbox. Hitbox dimensions are gameplay
--     constants (MovementConfig.Hitbox) and stay independent of Roblox rig size.
--   * It never moves the simulation out of blocks. Only the presentation
--     boundary (MovementMath.feetBlocksToRootStuds / toRootCFrame) consumes the
--     offset, plus the one-time spawn conversion root studs -> feet blocks.
--
-- Fallback
--   If the rig cannot be measured - no character, no Humanoid, no
--   HumanoidRootPart, a non-positive or non-finite HipHeight (R6 reports 0 and
--   is not described by the HipHeight rule), a non-positive root height, or a
--   result above the sanity ceiling - the documented fallback
--   Units.RootToFeetOffsetStudsFallback is returned with Source = "Fallback"
--   and a human-readable Detail. Callers log it once per character.
--
-- Client/server agreement
--   Both sides call `measure` on their own copy of the character. HipHeight and
--   root Size are replicated properties, so the same function returns the same
--   value on both; no extra networking is involved.

local MovementConfig = require(script.Parent.MovementConfig)

local RigOffset = {}

export type Source = "HipHeight" | "Fallback"

export type Measurement = {
	Studs: number,
	Source: Source,
	HipHeight: number?,
	RootHeightStuds: number?,
	Detail: string?,
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function fallback(detail: string): Measurement
	return {
		Studs = MovementConfig.Units.RootToFeetOffsetStudsFallback,
		Source = "Fallback",
		HipHeight = nil,
		RootHeightStuds = nil,
		Detail = detail,
	}
end

-- Pure: the whole validity rule, with no Roblox API involved.
-- `hipHeight` and `rootHeightStuds` are typed `any` on purpose: this is also the
-- validation boundary for values read from a live rig.
function RigOffset.fromGeometry(hipHeight: any, rootHeightStuds: any): Measurement
	if not isFiniteNumber(hipHeight) then
		return fallback("Humanoid.HipHeight is not a finite number")
	end
	if not isFiniteNumber(rootHeightStuds) then
		return fallback("HumanoidRootPart.Size.Y is not a finite number")
	end
	if hipHeight <= 0 then
		return fallback(
			string.format(
				"Humanoid.HipHeight is %.3f, so the HipHeight rule does not describe this rig",
				hipHeight
			)
		)
	end
	if rootHeightStuds <= 0 then
		return fallback(string.format("HumanoidRootPart.Size.Y is %.3f", rootHeightStuds))
	end

	local studs = hipHeight + rootHeightStuds / 2
	if studs > MovementConfig.Units.MaxRootToFeetOffsetStuds then
		return fallback(
			string.format(
				"measured %.3f studs, over the %.1f-stud sanity ceiling",
				studs,
				MovementConfig.Units.MaxRootToFeetOffsetStuds
			)
		)
	end

	return {
		Studs = studs,
		Source = "HipHeight",
		HipHeight = hipHeight,
		RootHeightStuds = rootHeightStuds,
		Detail = nil,
	}
end

-- Roblox-facing: reads a live rig. Nil-safe; reports instead of throwing, so a
-- character that is still assembling cannot abort session setup.
function RigOffset.fromRig(humanoid: Humanoid?, root: BasePart?): Measurement
	if humanoid == nil then
		return fallback("no Humanoid")
	end
	if root == nil then
		return fallback("no HumanoidRootPart")
	end
	return RigOffset.fromGeometry(humanoid.HipHeight, root.Size.Y)
end

function RigOffset.measure(character: Instance?): Measurement
	if character == nil then
		return fallback("no character")
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local basePart: BasePart? = nil
	if root ~= nil and root:IsA("BasePart") then
		basePart = root -- IsA narrows Instance to BasePart here
	end
	return RigOffset.fromRig(humanoid, basePart)
end

-- Convenience for logging: one line that says what was measured and where it
-- came from. Never used by simulation logic.
function RigOffset.describe(measurement: Measurement): string
	if measurement.Source == "HipHeight" then
		return string.format(
			"%.3f studs (HipHeight %.3f + half root %.3f)",
			measurement.Studs,
			measurement.HipHeight or 0,
			(measurement.RootHeightStuds or 0) / 2
		)
	end
	return string.format(
		"%.3f studs (FALLBACK: %s)",
		measurement.Studs,
		measurement.Detail or "rig could not be measured"
	)
end

return RigOffset
