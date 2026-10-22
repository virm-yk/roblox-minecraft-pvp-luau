--!strict
-- Collision
-- Deterministic, pure world collision for player-sized boxes. Knows nothing
-- about input, combat, networking, or the Roblox DataModel, and owns no
-- velocity logic.
--
-- All geometry is in BLOCKS. All deltas are in BLOCKS PER TICK.
--
-- WHAT THIS IS
--   A registry of static, axis-aligned, rectangular solid boxes plus the exact
--   1.9 AABB resolution used by Entity.moveEntity:
--     * one sweep box built with AxisAlignedBB.addCoord
--     * collision boxes collected ONCE from that swept box, strictly
--       intersecting it (World.func_184144_a -> Block.func_185492_a)
--     * Y, then X, then Z clipping over that same list
--       (AxisAlignedBB.calculateYOffset / calculateXOffset / calculateZOffset)
--     * collided flags derived from requested-vs-resolved deltas
--     * onGround = collided vertically while moving down
--
-- WHAT THIS IS NOT
--   * No step-up. Entity.moveEntity's stepHeight branch is deliberately
--     deferred; `StepUsed` is always false. The context argument already
--     carries what that branch needs.
--   * No sneak-edge shrink (the 0.05 probe loops). Also deferred; context
--     carries OnGround and Sneaking for it.
--   * No depenetration. If the box starts overlapping world boxes, the overlap
--     is REPORTED (`Penetrating`) and resolution proceeds exactly like vanilla,
--     which does not push an overlapping entity out. Do not invent a rule here;
--     the caller decides (reset/respawn).
--   * No entity-versus-entity collision. Player pushing is a separate behavior;
--     `collect` never returns entities.
--   * No skin width and no snapping. Contact is exact: `intersects` is strict,
--     so a box resting exactly on a surface does not intersect it, and movement
--     that ends exactly at a face resolves to that face.
--
-- Broad phase: registered boxes are bucketed into integer block cells, and a
-- query visits only the cells its box overlaps. Candidate order is sorted by
-- registration index, so results never depend on hash iteration order.

local MovementConfig = require(script.Parent.MovementConfig)

local Collision = {}

export type Box = {
	Min: Vector3,
	Max: Vector3,
}

export type World = {
	Boxes: { Box },
	Labels: { string? },
	Cells: { [string]: { number } },
	Count: number,
}

-- Historical name kept so existing type annotations (MovementMath, Reconcile)
-- keep resolving; a World is the collision world.
export type CollisionWorld = World

export type MoveContext = {
	-- Accepted now so the signature is stable; consumed when movement
	-- integration lands.
	OnGround: boolean?, -- gate for step-up and sneak-edge probes
	Sneaking: boolean?, -- enables the 0.05 sneak-edge shrink
	StepHeight: number?, -- 0 disables step-up; 1.9 uses Physics.StepHeight
}

export type MoveResult = {
	Box: Box, -- resolved box
	Position: Vector3, -- resolved feet position (bottom centre), blocks
	Delta: Vector3, -- resolved delta, blocks per tick
	Requested: Vector3, -- delta the caller asked for
	OnGround: boolean, -- collided while moving down THIS tick
	CollidedX: boolean,
	CollidedY: boolean,
	CollidedZ: boolean,
	CollidedHorizontally: boolean,
	CollidedVertically: boolean,
	StepUsed: boolean, -- always false in this stage
	Penetrating: boolean, -- box overlapped world geometry before the move
	CandidateCount: number, -- boxes that strictly intersected the swept box
}

local EMPTY_CONTEXT: MoveContext = {}

-- ===== Box construction and predicates =====

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Collision.isFiniteBox(box: Box): boolean
	return isFiniteNumber(box.Min.X)
		and isFiniteNumber(box.Min.Y)
		and isFiniteNumber(box.Min.Z)
		and isFiniteNumber(box.Max.X)
		and isFiniteNumber(box.Max.Y)
		and isFiniteNumber(box.Max.Z)
end

-- Normalises corner order the way the AxisAlignedBB constructor does.
function Collision.box(minX: number, minY: number, minZ: number, maxX: number, maxY: number, maxZ: number): Box
	return {
		Min = Vector3.new(math.min(minX, maxX), math.min(minY, maxY), math.min(minZ, maxZ)),
		Max = Vector3.new(math.max(minX, maxX), math.max(minY, maxY), math.max(minZ, maxZ)),
	}
end

-- Player AABB from a feet position (bottom-centre). Dimensions are the 1.9
-- EntityPlayer sizes: 0.6 wide, 1.8 tall, 1.65 while sneaking
-- (EntityPlayer.updateSize; both are also set by setSize(0.6F, 1.8F)).
function Collision.getPlayerBox(position: Vector3, sneaking: boolean): Box
	local hitbox = MovementConfig.Hitbox
	local height = if sneaking then hitbox.SneakHeight else hitbox.Height
	local halfWidth = hitbox.Width / 2
	return {
		Min = Vector3.new(position.X - halfWidth, position.Y, position.Z - halfWidth),
		Max = Vector3.new(position.X + halfWidth, position.Y + height, position.Z + halfWidth),
	}
end

-- Inverse of getPlayerBox for the horizontal centre. Height does not matter.
function Collision.boxToFeet(box: Box): Vector3
	local halfWidth = MovementConfig.Hitbox.Width / 2
	return Vector3.new(box.Min.X + halfWidth, box.Min.Y, box.Min.Z + halfWidth)
end

-- AxisAlignedBB.offset
function Collision.offset(box: Box, x: number, y: number, z: number): Box
	return {
		Min = Vector3.new(box.Min.X + x, box.Min.Y + y, box.Min.Z + z),
		Max = Vector3.new(box.Max.X + x, box.Max.Y + y, box.Max.Z + z),
	}
end

-- AxisAlignedBB.addCoord: extends only in the direction of travel, producing
-- the swept bounds used to gather candidates.
function Collision.addCoord(box: Box, x: number, y: number, z: number): Box
	local minX, minY, minZ = box.Min.X, box.Min.Y, box.Min.Z
	local maxX, maxY, maxZ = box.Max.X, box.Max.Y, box.Max.Z

	if x < 0 then
		minX += x
	elseif x > 0 then
		maxX += x
	end
	if y < 0 then
		minY += y
	elseif y > 0 then
		maxY += y
	end
	if z < 0 then
		minZ += z
	elseif z > 0 then
		maxZ += z
	end

	return {
		Min = Vector3.new(minX, minY, minZ),
		Max = Vector3.new(maxX, maxY, maxZ),
	}
end

-- AxisAlignedBB.func_186668_a: strict on every axis. Exact contact is NOT an
-- intersection, which is what makes "standing exactly on a block" stable.
function Collision.intersects(a: Box, b: Box): boolean
	return a.Min.X < b.Max.X
		and a.Max.X > b.Min.X
		and a.Min.Y < b.Max.Y
		and a.Max.Y > b.Min.Y
		and a.Min.Z < b.Max.Z
		and a.Max.Z > b.Min.Z
end

-- ===== World registry and broad phase =====

local function cellKey(cx: number, cy: number, cz: number): string
	return string.format("%d:%d:%d", cx, cy, cz)
end

-- Cells a box overlaps: floor(min) .. ceil(max) - 1 on each axis, which is the
-- same cell range World.func_184144_a visits for a query box.
local function cellRange(lo: number, hi: number): (number, number)
	local first = math.floor(lo)
	local last = math.ceil(hi) - 1
	if last < first then
		last = first
	end
	return first, last
end

function Collision.newWorld(): World
	return { Boxes = {}, Labels = {}, Cells = {}, Count = 0 }
end

-- Registers a static solid box. Registration order is the tie-break order for
-- candidates, and box volume must be positive: a zero-thickness "solid" is an
-- authoring error, not a valid collider.
function Collision.addBox(world: World, box: Box, label: string?): number
	if not Collision.isFiniteBox(box) then
		error("Collision.addBox: box has non-finite bounds", 2)
	end
	if box.Max.X <= box.Min.X or box.Max.Y <= box.Min.Y or box.Max.Z <= box.Min.Z then
		error("Collision.addBox: box must have positive volume", 2)
	end
	if world.Count >= MovementConfig.Collision.MaxBoxes then
		error(
			string.format(
				"Collision.addBox: world box budget exhausted (%d)",
				MovementConfig.Collision.MaxBoxes
			),
			2
		)
	end

	local index = world.Count + 1
	world.Boxes[index] = box
	world.Labels[index] = label
	world.Count = index

	local x0, x1 = cellRange(box.Min.X, box.Max.X)
	local y0, y1 = cellRange(box.Min.Y, box.Max.Y)
	local z0, z1 = cellRange(box.Min.Z, box.Max.Z)

	local cells = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
	if cells > MovementConfig.Collision.MaxCellsPerBox then
		error(
			string.format(
				"Collision.addBox: box spans %d cells, over the %d limit",
				cells,
				MovementConfig.Collision.MaxCellsPerBox
			),
			2
		)
	end

	for cx = x0, x1 do
		for cy = y0, y1 do
			for cz = z0, z1 do
				local key = cellKey(cx, cy, cz)
				local bucket = world.Cells[key]
				if bucket == nil then
					bucket = {}
					world.Cells[key] = bucket
				end
				table.insert(bucket, index)
			end
		end
	end

	return index
end

-- Convenience for the restricted test world: one full block at an integer cell.
function Collision.addBlock(world: World, cx: number, cy: number, cz: number, label: string?): number
	return Collision.addBox(
		world,
		Collision.box(cx, cy, cz, cx + 1, cy + 1, cz + 1),
		label or string.format("block(%d,%d,%d)", cx, cy, cz)
	)
end

-- Broad phase only: every registered box sharing a cell with the query box,
-- de-duplicated and sorted by registration index. May include boxes that do not
-- actually intersect.
function Collision.candidates(world: World, query: Box): { Box }
	local x0, x1 = cellRange(query.Min.X, query.Max.X)
	local y0, y1 = cellRange(query.Min.Y, query.Max.Y)
	local z0, z1 = cellRange(query.Min.Z, query.Max.Z)

	local seen: { [number]: boolean } = {}
	local indices: { number } = {}

	for cx = x0, x1 do
		for cy = y0, y1 do
			for cz = z0, z1 do
				local bucket = world.Cells[cellKey(cx, cy, cz)]
				if bucket ~= nil then
					for i = 1, #bucket do
						local index = bucket[i]
						if not seen[index] then
							seen[index] = true
							indices[#indices + 1] = index
						end
					end
				end
			end
		end
	end

	table.sort(indices)

	local out: { Box } = {}
	for i = 1, #indices do
		out[i] = world.Boxes[indices[i]]
	end
	return out
end

-- World collision collection (World.func_184144_a / getCollisionBoxes): candidate
-- boxes that strictly intersect the query box. This is the exact list
-- Entity.moveEntity clips against; it is gathered once per move.
function Collision.collect(world: World, query: Box): { Box }
	local out: { Box } = {}
	for _, candidate in ipairs(Collision.candidates(world, query)) do
		if Collision.intersects(candidate, query) then
			out[#out + 1] = candidate
		end
	end
	return out
end

function Collision.overlaps(world: World, box: Box): { Box }
	return Collision.collect(world, box)
end

-- ===== Axis clipping (AxisAlignedBB.calculate*Offset) =====
--
-- `entity` is the moving box, `obstacle` the static box, `delta` the remaining
-- displacement on that axis. The cross-axis overlap test is strict, and the
-- approach test is one-sided: a box that already overlaps the obstacle on the
-- movement axis is NOT clipped (vanilla has no depenetration).

function Collision.clipX(entity: Box, obstacle: Box, delta: number): number
	if
		entity.Max.Y > obstacle.Min.Y
		and entity.Min.Y < obstacle.Max.Y
		and entity.Max.Z > obstacle.Min.Z
		and entity.Min.Z < obstacle.Max.Z
	then
		if delta > 0 and entity.Max.X <= obstacle.Min.X then
			local gap = obstacle.Min.X - entity.Max.X
			if gap < delta then
				delta = gap
			end
		elseif delta < 0 and entity.Min.X >= obstacle.Max.X then
			local gap = obstacle.Max.X - entity.Min.X
			if gap > delta then
				delta = gap
			end
		end
	end
	return delta
end

function Collision.clipY(entity: Box, obstacle: Box, delta: number): number
	if
		entity.Max.X > obstacle.Min.X
		and entity.Min.X < obstacle.Max.X
		and entity.Max.Z > obstacle.Min.Z
		and entity.Min.Z < obstacle.Max.Z
	then
		if delta > 0 and entity.Max.Y <= obstacle.Min.Y then
			local gap = obstacle.Min.Y - entity.Max.Y
			if gap < delta then
				delta = gap
			end
		elseif delta < 0 and entity.Min.Y >= obstacle.Max.Y then
			local gap = obstacle.Max.Y - entity.Min.Y
			if gap > delta then
				delta = gap
			end
		end
	end
	return delta
end

function Collision.clipZ(entity: Box, obstacle: Box, delta: number): number
	if
		entity.Max.X > obstacle.Min.X
		and entity.Min.X < obstacle.Max.X
		and entity.Max.Y > obstacle.Min.Y
		and entity.Min.Y < obstacle.Max.Y
	then
		if delta > 0 and entity.Max.Z <= obstacle.Min.Z then
			local gap = obstacle.Min.Z - entity.Max.Z
			if gap < delta then
				delta = gap
			end
		elseif delta < 0 and entity.Min.Z >= obstacle.Max.Z then
			local gap = obstacle.Max.Z - entity.Min.Z
			if gap > delta then
				delta = gap
			end
		end
	end
	return delta
end

-- ===== Swept move (Entity.moveEntity, minus stepping and sneak-edge) =====

function Collision.moveEntity(world: World, box: Box, delta: Vector3, context: MoveContext?): MoveResult
	if not Collision.isFiniteBox(box) then
		error("Collision.moveEntity: box has non-finite bounds", 2)
	end
	if not isFiniteNumber(delta.X) or not isFiniteNumber(delta.Y) or not isFiniteNumber(delta.Z) then
		error("Collision.moveEntity: delta must be finite", 2)
	end

	-- Entity.moveEntity: isCollidedVertically is computed against the ORIGINAL
	-- y, so keep the requested values.
	local requestedX, requestedY, requestedZ = delta.X, delta.Y, delta.Z

	-- One gather for the whole sweep, from the swept bounds.
	local list = Collision.collect(world, Collision.addCoord(box, requestedX, requestedY, requestedZ))

	local y = requestedY
	for i = 1, #list do
		y = Collision.clipY(box, list[i], y)
	end
	local moved = Collision.offset(box, 0, y, 0)

	local x = requestedX
	for i = 1, #list do
		x = Collision.clipX(moved, list[i], x)
	end
	moved = Collision.offset(moved, x, 0, 0)

	local z = requestedZ
	for i = 1, #list do
		z = Collision.clipZ(moved, list[i], z)
	end
	moved = Collision.offset(moved, 0, 0, z)

	-- `context` is accepted but unused until movement integration: it carries
	-- the step-up gate (OnGround), the sneak-edge shrink (Sneaking) and the
	-- step height. Passing them now changes nothing; StepUsed stays false.
	local _ = context or EMPTY_CONTEXT

	local collidedVertically = requestedY ~= y
	local collidedX = requestedX ~= x
	local collidedZ = requestedZ ~= z

	return {
		Box = moved,
		Position = Collision.boxToFeet(moved),
		Delta = Vector3.new(x, y, z),
		Requested = Vector3.new(requestedX, requestedY, requestedZ),
		-- `this.onGround = this.isCollidedVertically && d4 < 0.0D`: a tick that
		-- does not move downward reports false even if the player is resting on
		-- a surface, exactly like the source.
		OnGround = collidedVertically and requestedY < 0,
		CollidedX = collidedX,
		CollidedY = collidedVertically,
		CollidedZ = collidedZ,
		CollidedHorizontally = collidedX or collidedZ,
		CollidedVertically = collidedVertically,
		StepUsed = false,
		-- Vanilla does not resolve an existing overlap. Report it instead so the
		-- caller can reset rather than silently tunneling.
		Penetrating = #Collision.collect(world, box) > 0,
		CandidateCount = #list,
	}
end

return Collision
