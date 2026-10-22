--!strict
-- CollisionAdapter
-- The one place Roblox geometry meets the collision system. It reads parts,
-- validates them, converts studs to blocks with the shared conversion helpers,
-- and registers static boxes into a pure Collision world.
--
-- SUPPORTED (explicitly registered test geometry only):
--   * class exactly `Part`
--   * Shape == Enum.PartType.Block (the default cube)
--   * Anchored == true, CanCollide == true
--   * orientation is identity: no rotation at all, not even 90 degrees, because
--     an axis-permuting rotation would also permute the size components
--   * finite, positive size
--
-- REJECTED, never approximated:
--   MeshPart, WedgePart, CornerWedgePart, TrussPart, UnionOperation,
--   NegateOperation, Terrain, SpawnLocation, Ball/Cylinder Part shapes, rotated
--   parts, unanchored parts. A rotated box is not a rotated AABB, and a mesh is
--   not a box; treating either as an exact Minecraft collider would be a silent
--   physics difference. `validatePrimitive` returns the reason, and
--   `fromFolder` either errors (Strict) or records it in the report.
--
-- IGNORED, by design:
--   * anything under a Model containing a Humanoid (character parts, accessory
--     handles) - the visual body never becomes world solid
--   * anything under a container named in Collision.IgnoreNames
--     (DebugGeometry/Visuals/Effects) or listed in options.Ignore
--
-- Geometry contract: the registered folder is authored on a 4-stud grid aligned
-- with the world origin, so one block = 4 studs = MovementConfig.Units.
-- StudsPerBlock. Conversion happens only here and in MovementMath.

local MovementConfig = require(script.Parent.MovementConfig)
local Collision = require(script.Parent.Collision)
local MovementMath = require(script.Parent.MovementMath)

local CollisionAdapter = {}

export type Primitive = {
	ClassName: string,
	Shape: any?, -- Enum.PartType for Part instances, nil for everything else
	Anchored: boolean,
	CanCollide: boolean,
	Size: Vector3, -- studs
	Position: Vector3, -- studs, part centre
	Rotation: { number }, -- 9 row-major CFrame rotation values (translation excluded)
	InsideCharacter: boolean?,
	InsideIgnored: boolean?,
}

export type Validation = {
	Ok: boolean,
	Category: string?, -- "Ignored" | "Excluded" | "Unsupported" when not Ok
	Reason: string?,
}

export type Rejection = {
	Part: BasePart?,
	Reason: string,
}

export type Report = {
	World: Collision.World,
	Accepted: number,
	Excluded: number,
	Ignored: number,
	Unsupported: { Rejection },
	MissingFolder: boolean?,
}

export type Options = {
	World: Collision.World?,
	Strict: boolean?, -- error on the first unsupported part instead of reporting
	Ignore: { Instance }?, -- extra instances whose descendants are skipped
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVector(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

-- CUSTOM: float slack for the orientation test, because a Part's CFrame is
-- stored as floats. It never widens collision geometry; it only decides whether
-- the stored rotation is close enough to identity to be treated as unrotated.
function CollisionAdapter.isUnrotated(rotation: { number }): boolean
	if #rotation < 9 then
		return false
	end
	local tolerance = MovementConfig.Collision.UnrotatedTolerance
	local identity = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
	for index = 1, 9 do
		local value = rotation[index]
		if not isFiniteNumber(value) then
			return false
		end
		if math.abs(value - identity[index]) > tolerance then
			return false
		end
	end
	return true
end

function CollisionAdapter.validatePrimitive(primitive: Primitive): Validation
	if primitive.InsideCharacter then
		return { Ok = false, Category = "Ignored", Reason = "inside a character model" }
	end
	if primitive.InsideIgnored then
		return { Ok = false, Category = "Ignored", Reason = "inside an ignored container" }
	end
	if not primitive.CanCollide then
		return { Ok = false, Category = "Excluded", Reason = "CanCollide is false" }
	end
	if primitive.ClassName ~= "Part" then
		return {
			Ok = false,
			Category = "Unsupported",
			Reason = string.format("unsupported class %q (only Part is supported)", primitive.ClassName),
		}
	end
	if primitive.Shape ~= Enum.PartType.Block then
		return {
			Ok = false,
			Category = "Unsupported",
			Reason = "unsupported shape (only PartType.Block is supported)",
		}
	end
	if not primitive.Anchored then
		return { Ok = false, Category = "Unsupported", Reason = "part is not anchored" }
	end
	if not isFiniteVector(primitive.Size) then
		return { Ok = false, Category = "Unsupported", Reason = "size is not finite" }
	end
	if primitive.Size.X <= 0 or primitive.Size.Y <= 0 or primitive.Size.Z <= 0 then
		return { Ok = false, Category = "Unsupported", Reason = "size must be positive" }
	end
	if not isFiniteVector(primitive.Position) then
		return { Ok = false, Category = "Unsupported", Reason = "position is not finite" }
	end
	if not CollisionAdapter.isUnrotated(primitive.Rotation) then
		return {
			Ok = false,
			Category = "Unsupported",
			Reason = "part is rotated (identity orientation required)",
		}
	end
	return { Ok = true }
end

-- Only valid for a primitive that passed validatePrimitive: studs -> blocks at
-- the adapter boundary, then a centre-extent box.
function CollisionAdapter.boxFromPrimitive(primitive: Primitive): Collision.Box
	local size = MovementMath.studsToBlocks(primitive.Size)
	local centre = MovementMath.studsToBlocks(primitive.Position)
	local halfX = size.X / 2
	local halfY = size.Y / 2
	local halfZ = size.Z / 2
	return Collision.box(
		centre.X - halfX,
		centre.Y - halfY,
		centre.Z - halfZ,
		centre.X + halfX,
		centre.Y + halfY,
		centre.Z + halfZ
	)
end

function CollisionAdapter.registerPrimitive(
	world: Collision.World,
	primitive: Primitive,
	label: string?
): (boolean, Validation)
	local validation = CollisionAdapter.validatePrimitive(primitive)
	if not validation.Ok then
		return false, validation
	end
	if world.Count >= MovementConfig.Collision.MaxBoxes then
		return false, {
			Ok = false,
			Category = "Unsupported",
			Reason = "collision box budget exhausted",
		}
	end
	Collision.addBox(world, CollisionAdapter.boxFromPrimitive(primitive), label)
	return true, validation
end

-- ===== Roblox-facing helpers =====

local function isInsideCharacter(part: BasePart): boolean
	for _, ancestor in ipairs(part:GetAncestors()) do
		if ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid") ~= nil then
			return true
		end
	end
	return false
end

local function isInsideIgnored(part: BasePart, options: Options): boolean
	local explicit: { [Instance]: boolean } = {}
	for _, instance in ipairs(options.Ignore or {}) do
		explicit[instance] = true
	end
	local names: { [string]: boolean } = {}
	for _, name in ipairs(MovementConfig.Collision.IgnoreNames) do
		names[name] = true
	end
	for _, ancestor in ipairs(part:GetAncestors()) do
		if explicit[ancestor] then
			return true
		end
		if names[ancestor.Name] then
			return true
		end
	end
	return false
end

function CollisionAdapter.describe(part: BasePart, options: Options): Primitive
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()
	local shape: any? = nil
	if part:IsA("Part") then
		shape = (part :: any).Shape
	end
	return {
		ClassName = part.ClassName,
		Shape = shape,
		Anchored = part.Anchored,
		CanCollide = part.CanCollide,
		Size = part.Size,
		Position = part.Position,
		Rotation = { r00, r01, r02, r10, r11, r12, r20, r21, r22 },
		InsideCharacter = isInsideCharacter(part),
		InsideIgnored = isInsideIgnored(part, options),
	}
end

-- Builds a world from a folder of static parts. Parts are visited in full-name
-- order so registration (and therefore candidate order and the report) is
-- deterministic regardless of DataModel iteration order.
function CollisionAdapter.fromFolder(folder: Instance?, options: Options?): (Collision.World, Report)
	local opts: Options = options or {}
	local world = opts.World or Collision.newWorld()
	local report: Report = {
		World = world,
		Accepted = 0,
		Excluded = 0,
		Ignored = 0,
		Unsupported = {},
	}

	if folder == nil then
		report.MissingFolder = true
		return world, report
	end

	local parts: { Instance } = {}
	for _, descendant in ipairs(folder:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	table.sort(parts, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	for _, part in ipairs(parts) do
		local primitive = CollisionAdapter.describe(part, opts)
		local registered, validation = CollisionAdapter.registerPrimitive(world, primitive, part:GetFullName())
		if registered then
			report.Accepted += 1
		elseif validation.Category == "Ignored" then
			report.Ignored += 1
		elseif validation.Category == "Excluded" then
			report.Excluded += 1
		else
			table.insert(report.Unsupported, { Part = part, Reason = validation.Reason or "unsupported" })
			if opts.Strict then
				error(
					string.format(
						"CollisionAdapter: unsupported collision geometry %s (%s)",
						part:GetFullName(),
						validation.Reason or "unsupported"
					),
					2
				)
			end
		end
	end

	return world, report
end

-- Convenience entry point for both scripts: builds the shared static world from
-- workspace.<Collision.WorldFolder>. Missing folder is reported, not fatal, so a
-- place without test geometry still runs.
function CollisionAdapter.fromWorkspace(options: Options?): (Collision.World, Report)
	local folder = workspace:FindFirstChild(MovementConfig.Collision.WorldFolder)
	local world, report = CollisionAdapter.fromFolder(folder, options)
	if report.MissingFolder then
		warn(
			string.format(
				"[CollisionAdapter] workspace.%s not found: collision world is empty",
				MovementConfig.Collision.WorldFolder
			)
		)
	end
	if #report.Unsupported > 0 then
		warn(
			string.format(
				"[CollisionAdapter] %d unsupported part(s) were not registered as solid; first: %s",
				#report.Unsupported,
				report.Unsupported[1].Reason
			)
		)
	end
	return world, report
end

return CollisionAdapter
