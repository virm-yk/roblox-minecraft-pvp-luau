--!strict
-- MovementMath
-- Pure movement stepping. No networking, no input gathering, no combat.
-- Position in BLOCKS, velocity in BLOCKS PER TICK.
-- The Humanoid is never used; velocity and position are explicit Luau values.
--
-- STATUS: FOUNDATION ONLY. Physics is not implemented in this stage.
-- `MovementMath.step` performs the authoritative timing/bookkeeping envelope and
-- then calls `stepPlayerTick`, whose phases are ordered like Java 1.9
-- `EntityLivingBase.onLivingUpdate` but are currently empty. Position and
-- velocity are therefore unchanged by a step.
--
-- Step envelope (implemented here):
--   * exactly one simulation tick per call, and only forward in time
--   * input generation must match the state generation
--   * LastAppliedInputSeq advances only by the consumed frame's Seq
--   * per-tick timers decay (hurt resistance), attack age advances
--   * per-tick collision flags are cleared
--
-- Physics order (TODO, movement stage; see STAGE1_INSPECTION.md section B.1):
--   1 resolveInput
--       IMPORTANT: frame.MoveForward/MoveStrafe arrive ALREADY sneak-scaled by
--       InputState.process (the 1.9 input-collection stage). Do NOT apply
--       Input.SneakScale here. This stage applies the 0.98 input damping
--       exactly once (EntityLivingBase:2344) and then moveFlying normalises.
--   2 cutoffMotion
--   3 applyJumpTick
--   4 travel (sampleFriction -> computeAcceleration -> moveFlying ->
--     ladder/fluid -> moveBox -> postMoveGravityAndDrag)
--   5 pushEntities
--   6 updateFallDistance

local MovementConfig = require(script.Parent.MovementConfig)
local MovementState = require(script.Parent.MovementState)
local InputState = require(script.Parent.InputState)
local Collision = require(script.Parent.Collision) -- type-only dependency

type State = MovementState.State
type InputFrame = InputState.InputFrame
type CollisionWorld = Collision.CollisionWorld

local MovementMath = {}

MovementMath.PHYSICS_IMPLEMENTED = false

-- ===== Roblox boundary conversions (the ONLY place studs and blocks meet) =====
--
-- Every function that crosses into Roblox space takes the root-to-feet offset
-- explicitly. It is measured per rig at runtime by RigOffset (HipHeight + half
-- the root height) and must be the SAME value used by the server and the client
-- for that character. There is no constant to fall back to here on purpose: a
-- silently wrong offset puts the whole rig at the wrong height.

function MovementMath.blocksToStuds(value: Vector3): Vector3
	return value * MovementConfig.Units.StudsPerBlock
end

function MovementMath.studsToBlocks(value: Vector3): Vector3
	return value / MovementConfig.Units.StudsPerBlock
end

local function requireOffset(rootToFeetOffsetStuds: number): number
	if
		type(rootToFeetOffsetStuds) ~= "number"
		or rootToFeetOffsetStuds ~= rootToFeetOffsetStuds
		or rootToFeetOffsetStuds == math.huge
		or rootToFeetOffsetStuds == -math.huge
		or rootToFeetOffsetStuds <= 0
	then
		error("MovementMath: root-to-feet offset must be a finite positive number of studs", 3)
	end
	return rootToFeetOffsetStuds
end

-- Feet position (blocks) -> HumanoidRootPart position (studs).
function MovementMath.feetBlocksToRootStuds(feet: Vector3, rootToFeetOffsetStuds: number): Vector3
	local offset = requireOffset(rootToFeetOffsetStuds)
	return MovementMath.blocksToStuds(feet) + Vector3.new(0, offset, 0)
end

-- HumanoidRootPart position (studs) -> feet position (blocks).
function MovementMath.rootStudsToFeetBlocks(root: Vector3, rootToFeetOffsetStuds: number): Vector3
	local offset = requireOffset(rootToFeetOffsetStuds)
	return MovementMath.studsToBlocks(root - Vector3.new(0, offset, 0))
end

-- Simulation state -> CFrame for the HumanoidRootPart.
-- Yaw convention: 0 degrees faces +Z, forward = (-sin(yaw), 0, cos(yaw)).
-- `presentationOffsetBlocks` is a presentation-only correction owned by the
-- client; it never feeds back into the simulation state.
function MovementMath.toRootCFrame(state: State, rootToFeetOffsetStuds: number, presentationOffsetBlocks: Vector3?): CFrame
	local offset = presentationOffsetBlocks or Vector3.zero
	local rootPosition = MovementMath.feetBlocksToRootStuds(state.Position + offset, rootToFeetOffsetStuds)
	local yaw = math.rad(state.Yaw)
	local forward = Vector3.new(-math.sin(yaw), 0, math.cos(yaw))
	return CFrame.lookAt(rootPosition, rootPosition + forward)
end

-- ===== Physics phases (not implemented in this stage) =====

function MovementMath.stepPlayerTick(state: State, frame: InputFrame, world: CollisionWorld)
	-- Physics is intentionally absent. Only the per-tick flag reset is real,
	-- so no caller can observe a collision flag left over from a previous tick.
	state.CollidedX = false
	state.CollidedY = false
	state.CollidedZ = false
	state.CollidedHorizontally = false
	state.CollidedVertically = false
	state.StepUsed = false

	-- TODO (movement stage), in this exact order:
	--   1 resolveInput
	--       axes are already sneak-scaled (input collection did that once).
	--       Apply only the per-tick damping (InputAxisDamping = 0.98) here,
	--       once, then evaluate sprint gates (forward >= SprintForwardThreshold,
	--       food, collided). Re-applying SneakScale would double-apply it.
	--   2 cutoffMotion       |velocity| < MotionCutoff -> 0
	--   3 applyJumpTick      jumpTicks--, jump, jumpTicks = JumpTicks / 0
	--   4 travel
	--       a sample the block under the feet BEFORE moving (slipperiness)
	--       b acceleration = onGround ? AIMoveSpeed * base / friction^3
	--                                   : jumpMovementFactor
	--       c moveFlying(strafe, forward, acceleration)
	--       d ladder clamp, then water/lava branches
	--       e Collision.moveEntity (Y/X/Z, exact flags; the step-up branch is
--         not implemented yet, so StepUsed is always false)
	--       f gravity and drag using the PRE-MOVE friction
	--   5 pushEntities
	--   6 updateFallDistance
	--
	-- `frame` is the validated input for this tick; `world` is the collision
	-- provider. Both are consumed by the phases above once implemented.
	local _ = frame
	local _ = world
end

-- ===== Public step =====

-- Advances exactly one simulation tick. Returns a NEW state; the input is not
-- mutated and the previous state is not modified.
function MovementMath.step(state: State, frame: InputFrame, world: CollisionWorld, serverTick: number): State
	local nextState = MovementState.clone(state)

	-- Time only moves forward. A duplicate or stale tick is not simulated.
	if serverTick <= state.ServerTick then
		return nextState
	end

	-- An input from another session generation must never touch this state.
	if frame.Generation ~= state.Generation then
		return nextState
	end

	nextState.ServerTick = serverTick

	-- Acknowledgement is monotonic and frame-driven: a starved/idle frame
	-- (Seq 0 or the already-applied Seq) never advances it.
	if frame.Seq > nextState.LastAppliedInputSeq then
		nextState.LastAppliedInputSeq = frame.Seq
	end

	-- Look direction and sneak posture request are input state, not physics.
	-- Sprinting is deliberately NOT taken from the frame: the client sends a
	-- request, and only the movement stage may grant it.
	nextState.Yaw = frame.Yaw
	nextState.Pitch = frame.Pitch
	nextState.Sneaking = frame.Sneak

	if nextState.HurtResistantTime > 0 then
		nextState.HurtResistantTime -= 1
	end
	if nextState.TicksSinceLastAttack < 1000000000 then
		nextState.TicksSinceLastAttack += 1
	end

	MovementMath.stepPlayerTick(nextState, frame, world)

	return nextState
end

return MovementMath
