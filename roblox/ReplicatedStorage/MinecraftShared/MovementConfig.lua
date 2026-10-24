--!strict
-- MovementConfig
-- Every numeric constant used by movement, collision, input, and movement networking.
--
-- Target: Minecraft Java Edition 1.9 (NOT 1.8.9, NOT 1.9.1+ / later versions).
--
-- Simulation units (explicit, never mixed):
--   Position  : BLOCKS (feet, bottom-center of the player hitbox)
--   Velocity  : BLOCKS PER TICK (Minecraft-native)
--   Roblox    : STUDS. Conversion happens only at the Roblox boundary
--               (see MovementMath.blocksToStuds / studsToBlocks).
--
-- TIMING MODEL (see MinecraftServer / MinecraftClient):
--   * The server owns `ServerTick`. It advances once per 1/20 s heartbeat step,
--     and each session receives EXACTLY ONE movement step per ServerTick.
--   * Clients assign `Seq`, a per-generation monotonic input sequence.
--   * The server's snapshot reports `LastAppliedInputSeq`: the highest input
--     sequence whose effects are included in the snapshot state.
--   * Packet arrival rate NEVER changes the physics step rate.
--
-- CLOCKS - two independent counters, never compared numerically:
--   * `Seq` / `LastAppliedInputSeq` order, de-duplicate, acknowledge, and replay
--     input. Nothing else.
--   * `ServerTick` is server simulation time and drives fixed-tick timers.
--   A state whose acknowledged Seq is far above (or below) its ServerTick is
--   completely valid: the client predicts at its own rate and the server drops
--   catch-up backlog under load, so the two counters drift by design.
--
-- INPUT PIPELINE (axis semantics introduced in schema 2, unchanged since):
--   raw key state (InputController)
--     -> InputState.process: opposing keys cancel, then the sneak multiplier
--        (Input.SneakScale) is applied ONCE, exactly where 1.9 applies it
--        (MovementInputFromOptions.updatePlayerMoveState).
--     -> InputFrame on the wire: axes are therefore already sneak-scaled and
--        deliberately NOT normalized (W+D has magnitude sqrt(2) * scale).
--     -> MovementMath.resolveInput: the 0.98 per-tick input damping is applied
--        ONCE (EntityLivingBase:2344), and moveFlying normalization happens
--        after that. Neither stage may repeat the other's work.
--
-- Values marked [VERIFY] were checked against the 1.9 reference during the
-- inspection stage; see STAGE1_INSPECTION.md for file/method evidence.

local MovementConfig = {}

MovementConfig.Target = "JavaEdition_1.9"

-- Bump when the wire/state schema changes incompatibly.
-- 2: MovementInput.MoveForward/MoveStrafe carry the PROCESSED (sneak-scaled)
--    axes rather than raw key axes. Shape and ordering are unchanged.
-- 3: the snapshot envelope carries RootToFeetOffsetStuds, the server-measured
--    rig offset the client must use for presentation. The movement State shape
--    is unchanged; an old client rejects a schema-3 snapshot instead of
--    guessing a root height.
MovementConfig.SchemaVersion = 3

MovementConfig.Simulation = {
	TicksPerSecond = 20,
	MaxCatchUpTicks = 5, -- max fixed ticks run in one frame before the backlog is dropped
}
MovementConfig.Simulation.TickDuration = 1 / MovementConfig.Simulation.TicksPerSecond

-- ===== Custom controller ownership =====
-- Both scripts read this table, so enable/disable is always symmetric.
-- When Enabled is false the server creates no sessions and the client neither
-- predicts nor writes CFrame; the Humanoid is left completely untouched.
MovementConfig.Control = {
	Enabled = true,
	AnchorCharacter = true, -- root.Anchored = true while the controller owns the character
	DisableHumanoid = true, -- AutoRotate=false, WalkSpeed=0, JumpPower=0
	RestoreOnTeardown = true, -- restore the properties above on character removal/replace
	SetupTimeoutSeconds = 10, -- WaitForChild timeout for late/stale character setup
}

MovementConfig.Units = {
	StudsPerBlock = 4,
	-- Visual HumanoidRootPart centre -> feet distance. There is deliberately no
	-- single constant: it is measured per rig at runtime by RigOffset from
	-- Humanoid.HipHeight and HumanoidRootPart.Size.Y (HipHeight + half the root
	-- height), because HipHeight is authored per place and per rig. These two
	-- values only bound that measurement.
	RootToFeetOffsetStudsFallback = 3, -- documented fallback when the rig cannot be measured
	MaxRootToFeetOffsetStuds = 32, -- sanity ceiling; a larger result is treated as unmeasurable
}

MovementConfig.Physics = {
	Gravity = 0.08, -- blocks/tick^2
	VerticalDrag = 0.98,
	JumpVelocity = 0.42, -- blocks/tick
	JumpTicks = 10, -- holding jump re-jumps every 10 ticks; releasing clears the timer
	SprintJumpHorizontalBoost = 0.2, -- blocks/tick along facing when sprint-jumping

	BaseMovementSpeed = 0.1, -- MOVEMENT_SPEED attribute base
	SprintSpeedMultiplier = 1.3, -- +0.3 attribute modifier, operation 2
	SprintForwardThreshold = 0.8, -- raw forward input required to sprint
	FoodSprintMinimum = 6, -- foodLevel must be > this to start/keep sprinting

	SlipperinessDefault = 0.6,
	GroundDragFactor = 0.91, -- multiplied by block slipperiness while onGround
	AirDragFactor = 0.91, -- literal value while airborne (no slipperiness lookup)
	GroundAccelerationBase = 0.16277136, -- f7 = base / friction^3
	AirAcceleration = 0.02, -- jumpMovementFactor while walking
	SprintAirAcceleration = 0.026, -- jumpMovementFactor while sprinting

	InputAxisDamping = 0.98, -- applied once per tick to fresh input axes
	MotionCutoff = 0.003, -- |velocity| below this is zeroed before the move
	StepHeight = 0.6,
}

MovementConfig.Hitbox = {
	Width = 0.6,
	Height = 1.8,
	SneakHeight = 1.65,
	EyeHeight = 1.62,
	SneakEyeHeight = 1.54,
}

-- ===== Static collision world =====
-- Collision itself resolves exact AABBs with no epsilon. These values only
-- configure the registry and the Roblox adapter, never the resolution math.
--
-- There is deliberately NO skin width and NO ground-probe distance: 1.9 uses
-- strict inequalities and exact contact, and an arbitrary epsilon would change
-- where the player comes to rest.
MovementConfig.Collision = {
	WorldFolder = "World", -- only parts under workspace.World are registered as solid
	IgnoreNames = { "DebugGeometry", "Visuals", "Effects" }, -- never treated as solid
	MaxBoxes = 8192,
	MaxCellsPerBox = 4096, -- a box over this cap is rejected and reported, never split or clipped
	UnrotatedTolerance = 0.0001, -- CUSTOM: float slack when checking part orientation
	RebuildDebounceSeconds = 0.25, -- coalesce bursts of folder/part changes into one rebuild
}

MovementConfig.Input = {
	MaxAxis = 1,
	PitchLimitDegrees = 90,
	SneakScale = 0.3, -- applied to input axes at input collection (also blocks sprint)
	DoubleTapWindowTicks = 7, -- 1.9 sprintToggleTimer: 7 ticks to complete the double tap
	Keys = {
		Forward = Enum.KeyCode.W,
		Back = Enum.KeyCode.S,
		Left = Enum.KeyCode.A,
		Right = Enum.KeyCode.D,
		Jump = Enum.KeyCode.Space,
		Sprint = Enum.KeyCode.LeftControl,
		Sneak = Enum.KeyCode.LeftShift,
	},
}

MovementConfig.Network = {
	MaxInputMessagesPerSecond = 40, -- 2x tick rate, tolerates bursts
	MaxResyncMessagesPerSecond = 4,
	MaxInputFields = 11, -- Kind, Generation, Seq, ClientTick + 7 input fields
	MaxResetKindLength = 32,
}

-- ===== Server input queue policy (InputQueue) =====
MovementConfig.InputQueue = {
	MaxQueued = 12, -- must exceed Simulation.MaxCatchUpTicks plus network jitter
	MaxSequenceJump = 40, -- largest allowed gap ahead of the acknowledged sequence
	GapWaitTicks = 4, -- ticks to wait for a missing sequence before resyncing
	StarveWarnTicks = 20, -- telemetry threshold only
	IdleTimeoutTicks = 100, -- 5 s without any applicable input: stop stepping, mark stale
}

-- ===== Client prediction / reconciliation =====
MovementConfig.Prediction = {
	MaxPendingInputs = 60, -- 3 s of unacknowledged input; overflow forces a resync
	SnapDistanceBlocks = 1.5, -- presentation correction larger than this snaps
	OffsetDecayPerSecond = 12, -- exponential decay of the presentation-only offset
	RequestCooldownSeconds = 1, -- min spacing between client resync requests
	MaxInvalidSnapshots = 5, -- consecutive malformed snapshots before a resync request
}

-- Debug readout (client only). Not part of the wire contract.
MovementConfig.Debug = {
	Enabled = true,
	ToggleKey = Enum.KeyCode.F3,
	RefreshSeconds = 0.1,
}

MovementConfig.Server = {
	StateSnapshotIntervalTicks = 2, -- 10 Hz
	MaxSpeedBlocksPerTick = 4.5, -- plausibility bound (terminal fall is 3.92)
	MaxCoordinateBlocks = 29999999, -- matches the source clamp (2.9999999E7)
	ResyncCooldownTicks = 20, -- min spacing between server-initiated resets
}

-- RemoteEvent names and folder are part of the existing Explorer contract.
-- Payload shapes may change; these names may not.
MovementConfig.Remotes = {
	Folder = "Remotes",
	Input = "MovementInput", -- client -> server: { Kind = "Input", ... } or { Kind = "Resync", ... }
	State = "MovementState", -- server -> client: Snapshot (see Reconcile.Snapshot)
}

return MovementConfig
