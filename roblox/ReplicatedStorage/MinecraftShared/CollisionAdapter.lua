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
-- OVERSIZED, never truncated:
--   A box that would be bucketed into more than Collision.MaxCellsPerBox cells is
--   rejected with Category "Oversized" and a reason that states the cell count,
--   the cap, and the part responsible. It is NOT clipped, split, or dropped
--   silently, and it cannot abort a rebuild: the check happens before
--   Collision.addBox, which would otherwise raise.
--
-- IGNORED, by design:
--   * anything under a Model containing a Humanoid (character parts, accessory
--     handles) - the visual body never becomes world solid
--   * anything under a container named in Collision.IgnoreNames
--     (DebugGeometry/Visuals/Effects) or listed in options.Ignore
--
-- REBUILDING (CollisionAdapter.watch):
--   A world is static for as long as it is used, but the place is not frozen.
--   `watch` keeps one World reference current:
--     * builds immediately, even when workspace.World does not exist yet;
--     * rescans when the folder appears, disappears, is reparented, gains or
--       loses descendants, or when a registered part's geometry changes;
--     * swaps in a BRAND NEW world on every rebuild, so no box is ever
--       registered twice and a failed build cannot leave a half-populated
--       world behind;
--     * coalesces bursts of changes with Collision.RebuildDebounceSeconds.
--   Callers read `watched.World` at use time; they must not cache it.
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
	Category: string?, -- "Ignored" | "Excluded" | "Unsupported" | "Oversized" when not Ok
	Reason: string?,
}

export type Rejection = {
	Part: BasePart?,
	Reason: string,
	Category: string?,
}

export type Report = {
	World: Collision.World,
	Accepted: number,
	Excluded: number,
	Ignored: number,
	Oversized: number, -- rejected because a single box exceeded MaxCellsPerBox
	Unsupported: { Rejection }, -- includes the oversized entries, with their reasons
	MissingFolder: boolean?,
}

export type Options = {
	World: Collision.World?,
	Strict: boolean?, -- error on the first unsupported part instead of reporting
	Ignore: { Instance }?, -- extra instances whose descendants are skipped
}

-- Returned by `watch`. `World` is the only field callers read during play;
-- everything else exists for diagnostics and teardown.
export type Watched = {
	Options: Options,
	World: Collision.World,
	Report: Report,
	Version: number,
	Rebuilds: number,
	LastRebuildReason: string?,
	Folder: Instance?,
	Destroyed: boolean,
	OnRebuilt: (((Collision.World, Report, string?) -> ()))?,
	Connections: { RBXScriptConnection },
	PartConnections: { RBXScriptConnection },
	Scheduled: boolean,
	PendingReason: string?,
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

	local box = CollisionAdapter.boxFromPrimitive(primitive)
	local cells = Collision.cellCount(box)
	local cap = MovementConfig.Collision.MaxCellsPerBox
	if cells > cap then
		-- Reported before addBox, which raises on the same condition. A single
		-- oversized part must not abort a whole rebuild.
		return false, {
			Ok = false,
			Category = "Oversized",
			Reason = string.format(
				"oversized: %s would span %d block cells, over the %d-cell cap; split it into smaller parts",
				label or "primitive",
				cells,
				cap
			),
		}
	end

	if world.Count >= MovementConfig.Collision.MaxBoxes then
		return false, {
			Ok = false,
			Category = "Unsupported",
			Reason = string.format(
				"collision box budget exhausted (%d boxes); %s was not registered",
				MovementConfig.Collision.MaxBoxes,
				label or "primitive"
			),
		}
	end

	Collision.addBox(world, box, label)
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
		Oversized = 0,
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
			if validation.Category == "Oversized" then
				report.Oversized += 1
			end
			table.insert(report.Unsupported, {
				Part = part,
				Reason = validation.Reason or "unsupported",
				Category = validation.Category,
			})
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

local function warnReport(report: Report, context: string)
	if report.MissingFolder then
		warn(
			string.format(
				"[CollisionAdapter] workspace.%s not found (%s): collision world is empty until it appears",
				MovementConfig.Collision.WorldFolder,
				context
			)
		)
	end
	local firstOversized, firstUnsupported = nil, nil
	for _, rejection in ipairs(report.Unsupported) do
		if rejection.Category == "Oversized" then
			firstOversized = firstOversized or rejection.Reason
		else
			firstUnsupported = firstUnsupported or rejection.Reason
		end
	end
	if report.Oversized > 0 then
		warn(
			string.format(
				"[CollisionAdapter] %d oversized part(s) were REJECTED, not clipped (%s); first: %s",
				report.Oversized,
				context,
				firstOversized or "see report"
			)
		)
	end
	if #report.Unsupported > report.Oversized then
		warn(
			string.format(
				"[CollisionAdapter] %d unsupported part(s) were not registered as solid (%s); first: %s",
				#report.Unsupported - report.Oversized,
				context,
				firstUnsupported or "see report"
			)
		)
	end
end

-- Convenience entry point: one-shot build from workspace.<Collision.WorldFolder>.
-- Missing folder is reported, not fatal. Prefer `watch` for anything that keeps
-- running, because a one-shot build cannot notice later geometry.
function CollisionAdapter.fromWorkspace(options: Options?): (Collision.World, Report)
	local folder = workspace:FindFirstChild(MovementConfig.Collision.WorldFolder)
	local world, report = CollisionAdapter.fromFolder(folder, options)
	warnReport(report, "one-shot build")
	return world, report
end

-- ===== Watched world (rescan on change, never duplicate) =====

local function disconnectAll(connections: { RBXScriptConnection })
	for index = #connections, 1, -1 do
		connections[index]:Disconnect()
		connections[index] = nil
	end
end

local function watchPart(watched: Watched, part: BasePart)
	local function changed()
		CollisionAdapter.scheduleRebuild(watched, "PartPropertyChanged")
	end

	local properties = { "Size", "Anchored", "CanCollide" }
	if part:IsA("Part") then
		table.insert(properties, "Shape")
	end
	if part.Anchored then
		-- Unanchored parts move every physics step; they are rejected anyway, so
		-- watching their CFrame would only churn rebuilds.
		table.insert(properties, "CFrame")
	end
	for _, property in ipairs(properties) do
		table.insert(watched.PartConnections, part:GetPropertyChangedSignal(property):Connect(changed))
	end
end

local function attachWatchers(watched: Watched)
	disconnectAll(watched.Connections)
	disconnectAll(watched.PartConnections)

	local function schedule()
		CollisionAdapter.scheduleRebuild(watched, "WorldChanged")
	end

	local folder = watched.Folder
	if folder ~= nil then
		table.insert(
			watched.Connections,
			folder.DescendantAdded:Connect(function()
				schedule()
			end)
		)
		table.insert(
			watched.Connections,
			folder.DescendantRemoving:Connect(function()
				schedule()
			end)
		)
		table.insert(
			watched.Connections,
			folder.AncestryChanged:Connect(function()
				schedule()
			end)
		)
		table.insert(
			watched.Connections,
			folder:GetPropertyChangedSignal("Name"):Connect(function()
				-- rename away from/towards World changes which folder is authoritative
				CollisionAdapter.scheduleRebuild(watched, "FolderRenamed")
			end)
		)
		for _, descendant in ipairs(folder:GetDescendants()) do
			if descendant:IsA("BasePart") then
				watchPart(watched, descendant)
			end
		end
	end

	-- The folder itself may be created, destroyed, or replaced at any time.
	table.insert(
		watched.Connections,
		workspace.ChildAdded:Connect(function(child)
			if child.Name == MovementConfig.Collision.WorldFolder then
				CollisionAdapter.scheduleRebuild(watched, "WorldAdded")
			end
		end)
	)
	table.insert(
		watched.Connections,
		workspace.ChildRemoved:Connect(function(child)
			if child.Name == MovementConfig.Collision.WorldFolder then
				CollisionAdapter.scheduleRebuild(watched, "WorldRemoved")
			end
		end)
	)
end

-- Rebuilds now, into a new World. Safe to call at any time; never nests.
function CollisionAdapter.rebuild(watched: Watched, reason: string?): (Collision.World, Report)
	if watched.Destroyed then
		return watched.World, watched.Report
	end

	local label = reason or "Manual"
	local folder = workspace:FindFirstChild(MovementConfig.Collision.WorldFolder)
	watched.Folder = folder
	-- Attach first, so a part added while the world is being built still
	-- schedules the next rebuild instead of slipping through the gap.
	attachWatchers(watched)

	local options: Options = {
		Strict = watched.Options.Strict,
		Ignore = watched.Options.Ignore,
	}
	local world, report = CollisionAdapter.fromFolder(folder, options)

	watched.World = world
	watched.Report = report
	watched.Version += 1
	watched.Rebuilds += 1
	watched.LastRebuildReason = label

	local summary = string.format(
		"[CollisionAdapter] world v%d rebuilt (%s): %d accepted, %d excluded, %d ignored, %d oversized, %d unsupported",
		watched.Version,
		label,
		report.Accepted,
		report.Excluded,
		report.Ignored,
		report.Oversized,
		#report.Unsupported
	)
	if report.MissingFolder then
		warn(summary)
	else
		print(summary)
	end
	warnReport(report, label)

	if watched.OnRebuilt ~= nil then
		watched.OnRebuilt(world, report, label)
	end
	return world, report
end

-- Coalesces changes: the first change starts one timer; every change before it
-- fires only replaces the pending reason. Callers therefore see at most one
-- rebuild per RebuildDebounceSeconds, always of the latest state.
function CollisionAdapter.scheduleRebuild(watched: Watched, reason: string?)
	if watched.Destroyed then
		return
	end
	watched.PendingReason = reason
	if watched.Scheduled then
		return
	end
	watched.Scheduled = true
	task.delay(MovementConfig.Collision.RebuildDebounceSeconds, function()
		watched.Scheduled = false
		if watched.Destroyed then
			return
		end
		local pending = watched.PendingReason
		watched.PendingReason = nil
		CollisionAdapter.rebuild(watched, pending or "Scheduled")
	end)
end

function CollisionAdapter.stopWatching(watched: Watched)
	watched.Destroyed = true
	watched.Scheduled = false
	watched.PendingReason = nil
	disconnectAll(watched.Connections)
	disconnectAll(watched.PartConnections)
end

-- Builds the first world immediately, then keeps it current. Returns the live
-- handle; read `watched.World` at use time rather than caching it. Options.World
-- is ignored on purpose: a watched handle always owns a world it built itself,
-- which is what makes "a rebuild never duplicates a box" true.
function CollisionAdapter.watch(
	options: Options?,
	onRebuilt: ((Collision.World, Report, string?) -> ())?
): Watched
	local emptyWorld = Collision.newWorld()
	local watched: Watched = {
		Options = options or {},
		World = emptyWorld,
		Report = {
			World = emptyWorld,
			Accepted = 0,
			Excluded = 0,
			Ignored = 0,
			Oversized = 0,
			Unsupported = {},
		},
		Version = 0,
		Rebuilds = 0,
		LastRebuildReason = nil,
		Folder = nil,
		Destroyed = false,
		OnRebuilt = onRebuilt,
		Connections = {},
		PartConnections = {},
		Scheduled = false,
		PendingReason = nil,
	}
	CollisionAdapter.rebuild(watched, "Initial")
	return watched
end

return CollisionAdapter
