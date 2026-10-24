--!nonstrict
-- MinecraftClient
-- Client entry point. Responsibilities:
--   * gather raw input through InputController into a sequenced InputFrame
--   * run the fixed-tick prediction loop
--   * send input and resync requests over the MovementInput RemoteEvent
--   * reconcile against authoritative snapshots (full state, generation-gated)
--   * smooth presentation separately from simulation
--
-- Timeline model:
--   The server owns ServerTick and acknowledges inputs with LastAppliedInputSeq.
--   This client assigns Seq per generation, predicts one step per 1/20 s, and
--   replays every unacknowledged frame on top of each authoritative snapshot.
--   It never sends input before it has adopted a generation from a snapshot, so
--   input can never be attributed to the wrong character.
--
--   Seq and ServerTick are independent clocks and are never compared. Seq only
--   orders/acknowledges/replays input; ServerTick only drives simulation time
--   and snapshot ordering.
--
-- Combat is disabled at this stage; the server still owns the combat remotes.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MinecraftShared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local MovementMath = require(Shared:WaitForChild("MovementMath"))
local CollisionAdapter = require(Shared:WaitForChild("CollisionAdapter"))
local InputState = require(Shared:WaitForChild("InputState")) -- neutral frame for the debug readout
local Reconcile = require(Shared:WaitForChild("Reconcile"))
local RigOffset = require(Shared:WaitForChild("RigOffset"))

-- Both live beside this LocalScript under PlayerScripts at runtime.
local InputController = require(script.Parent:WaitForChild("InputController"))
local InputDebugOverlay = require(script.Parent:WaitForChild("InputDebugOverlay"))

-- Static collision geometry, kept current by a watched rebuild. Prediction
-- reads collision.World at replay time, so geometry added after startup is used
-- and a rebuild can never double-register a box. Characters and debug models
-- are never registered as world solid.
local collision = CollisionAdapter.watch({ Strict = false })

local localPlayer = Players.LocalPlayer
local input = InputController.new()
local overlay = if MovementConfig.Debug.Enabled then InputDebugOverlay.new() else nil

-- ===== Networking =====

local remotesFolder = Shared:WaitForChild(MovementConfig.Remotes.Folder)
local inputRemote = remotesFolder:WaitForChild(MovementConfig.Remotes.Input)
local stateRemote = remotesFolder:WaitForChild(MovementConfig.Remotes.State)

-- ===== Local state =====

local current = {
	generation = 0, -- last accepted session generation; survives respawns on purpose
	lastSnapshotTick = 0,
	predicted = nil,
	pending = {}, -- sent frames with Seq > acknowledged Seq, ascending
	nextSeq = 1,
	localTick = 0,
	ready = false,
	awaitingNewGeneration = false, -- set on respawn; blocks snapshots from the old body
	awaitingResync = false,
	invalidSnapshots = 0,
	offset = Vector3.zero, -- presentation-only correction, in BLOCKS
	rootPart = nil,
	-- Authoritative offset from the latest accepted snapshot. Until one arrives
	-- (RenderStepped is gated on `ready`), the documented fallback is used.
	rootToFeetOffsetStuds = MovementConfig.Units.RootToFeetOffsetStudsFallback,
	localRootToFeetOffsetStuds = nil, -- this client's own measurement, diagnostics only
	offsetMismatchWarned = false,
	characterToken = 0,
	controller = nil,
	lastResyncRequest = -math.huge,
	stepAccumulator = 0,
	-- Diagnostics for the debug readout only; never read by simulation logic.
	debugFrame = nil,
	debugRawForward = 0,
	debugRawStrafe = 0,
	lastSentSeq = 0,
}

-- ===== Input gathering =====

local function getLookAngles()
	local camera = workspace.CurrentCamera
	if not camera then
		return 0, 0
	end
	local look = camera.CFrame.LookVector
	-- Yaw 0 faces +Z; positive pitch looks down. Matches MovementMath.toRootCFrame.
	local yaw = math.deg(math.atan2(-look.X, look.Z))
	local pitch = math.deg(-math.asin(math.clamp(look.Y, -1, 1)))
	return yaw, pitch
end

-- Raw key state lives in InputController and is polled once per tick. This
-- function only supplies the look angles. The returned frame carries PROCESSED
-- axes: opposing keys already cancelled, sneak multiplier already applied once
-- at collection. Nothing here damps or normalises them.
local function buildFrame()
	local yaw, pitch = getLookAngles()
	local frame, rawForward, rawStrafe =
		InputController.gather(input, current.generation, current.nextSeq, current.localTick, yaw, pitch)
	current.debugFrame = frame
	current.debugRawForward = rawForward
	current.debugRawStrafe = rawStrafe
	return frame
end

-- Axes are already sneak-scaled. The server clamps them against the claimed
-- sneak flag instead of scaling again, so the multiplier is applied exactly once.
local function sendFrame(frame)
	current.lastSentSeq = frame.Seq
	inputRemote:FireServer({
		Kind = "Input",
		Generation = frame.Generation,
		Seq = frame.Seq,
		ClientTick = frame.ClientTick,
		MoveForward = frame.MoveForward,
		MoveStrafe = frame.MoveStrafe,
		Jump = frame.Jump,
		Sprint = frame.Sprint,
		Sneak = frame.Sneak,
		Yaw = frame.Yaw,
		Pitch = frame.Pitch,
	})
end

-- Explicit recovery. The server replies with a higher-generation Reset.
local function requestResync(reason)
	if current.generation <= 0 then
		return
	end
	local now = os.clock()
	if now - current.lastResyncRequest < MovementConfig.Prediction.RequestCooldownSeconds then
		return
	end
	current.lastResyncRequest = now
	current.awaitingResync = true
	inputRemote:FireServer({
		Kind = "Resync",
		Generation = current.generation,
		LastAckedSeq = current.predicted ~= nil and current.predicted.LastAppliedInputSeq or 0,
	})
	print("[MinecraftClient] resync requested:", reason)
end

-- ===== Snapshot handling =====

local function onSnapshot(payload)
	if not MovementConfig.Control.Enabled then
		return
	end

	local snapshot = Reconcile.parseSnapshot(payload)
	if snapshot == nil then
		current.invalidSnapshots += 1
		if current.invalidSnapshots >= MovementConfig.Prediction.MaxInvalidSnapshots then
			current.invalidSnapshots = 0
			requestResync("InvalidSnapshot")
		end
		return
	end

	-- Setup may still be running (or this is a stale character). The server
	-- resends periodically, so dropping this one loses nothing.
	if current.rootPart == nil then
		return
	end

	-- After a respawn, nothing from the previous generation may be adopted, not
	-- even a snapshot whose tick looks newer than the last one we saw.
	if current.awaitingNewGeneration and snapshot.Generation <= current.generation then
		return
	end

	local acceptance = Reconcile.shouldAccept(snapshot, current.generation, current.lastSnapshotTick)
	if acceptance == "Stale" then
		return
	end

	local isNewGeneration = acceptance == "NewGeneration"

	-- The server's measured offset is authoritative for presentation. A local
	-- difference is worth one warning: it means the two copies of the rig do not
	-- match, which would otherwise show up as a permanent height fight.
	local localOffset = current.localRootToFeetOffsetStuds
	if
		localOffset ~= nil
		and math.abs(localOffset - snapshot.RootToFeetOffsetStuds) > 0.001
		and not current.offsetMismatchWarned
	then
		current.offsetMismatchWarned = true
		warn(
			string.format(
				"[MinecraftClient] rig offset disagreement: local %.3f, server %.3f; presenting with the server value",
				localOffset,
				snapshot.RootToFeetOffsetStuds
			)
		)
	end
	current.rootToFeetOffsetStuds = snapshot.RootToFeetOffsetStuds

	if isNewGeneration then
		current.generation = snapshot.Generation
		current.awaitingNewGeneration = false
		current.lastSnapshotTick = 0
		current.pending = {}
		current.nextSeq = 1
		current.localTick = 0
		current.awaitingResync = false
		current.invalidSnapshots = 0
		current.offset = Vector3.zero
		current.predicted = nil
		-- A new body must not inherit held keys or a half-finished double tap.
		InputController.reset(input, snapshot.Generation)
	end

	-- The authoritative state is ALWAYS the replay base. Velocity, flags,
	-- timers, and health are corrected even when position barely moved.
	local updated, remaining, _replayed = Reconcile.apply(snapshot.State, current.pending, collision.World)

	local offset = Reconcile.computeOffset(
		current.predicted,
		updated,
		current.offset,
		MovementConfig.Prediction.SnapDistanceBlocks
	)

	if isNewGeneration or snapshot.Reset then
		-- A reset means the input history is gone; do not keep a visual delta
		-- that belongs to the old stream.
		current.pending = {}
		offset = Vector3.zero
	end

	current.offset = offset
	current.pending = remaining
	current.predicted = updated
	current.lastSnapshotTick = snapshot.ServerTick
	current.ready = true
	current.invalidSnapshots = 0

	-- Never reuse a sequence the server has already acknowledged.
	if snapshot.LastAppliedInputSeq + 1 > current.nextSeq then
		current.nextSeq = snapshot.LastAppliedInputSeq + 1
	end
end

stateRemote.OnClientEvent:Connect(onSnapshot)

-- ===== Prediction =====

local function stepClientTick()
	if not current.ready or current.predicted == nil or current.awaitingResync then
		return
	end

	if not Reconcile.canPredict(#current.pending) then
		-- History is full. Never drop pending frames and continue: that would
		-- replay a history the server can never reproduce.
		requestResync("PendingOverflow")
		return
	end

	local frame = buildFrame()
	current.nextSeq += 1
	current.localTick += 1

	local nextState = MovementMath.step(current.predicted, frame, collision.World, current.predicted.ServerTick + 1)

	current.predicted = nextState
	table.insert(current.pending, frame)
	sendFrame(frame)
end

-- ===== Character lifecycle =====

local function restoreClientController()
	local record = current.controller
	current.controller = nil
	if record == nil or not MovementConfig.Control.RestoreOnTeardown then
		return
	end
	local root = record.Root
	if root ~= nil and root.Parent ~= nil then
		pcall(function()
			root.Anchored = record.WasAnchored
		end)
	end
	local humanoid = record.Humanoid
	if humanoid ~= nil and humanoid.Parent ~= nil then
		pcall(function()
			humanoid.AutoRotate = record.AutoRotate
			humanoid.WalkSpeed = record.WalkSpeed
			humanoid.JumpPower = record.JumpPower
		end)
	end
end

local function takeClientControl(root, humanoid)
	if not MovementConfig.Control.Enabled then
		return nil
	end
	local record = {
		Root = root,
		Humanoid = humanoid,
		WasAnchored = root.Anchored,
		AutoRotate = humanoid.AutoRotate,
		WalkSpeed = humanoid.WalkSpeed,
		JumpPower = humanoid.JumpPower,
	}
	if MovementConfig.Control.AnchorCharacter then
		root.Anchored = true
	end
	if MovementConfig.Control.DisableHumanoid then
		humanoid.AutoRotate = false
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	end
	return record
end

local function resetPrediction()
	current.ready = false
	current.awaitingNewGeneration = true
	current.awaitingResync = false
	current.predicted = nil
	current.pending = {}
	current.nextSeq = 1
	current.localTick = 0
	current.offset = Vector3.zero
	current.stepAccumulator = 0
	current.invalidSnapshots = 0
	current.lastSnapshotTick = 0
end

local function onCharacterAdded(character)
	current.characterToken += 1
	local token = current.characterToken

	restoreClientController()
	resetPrediction()
	InputController.reset(input, current.generation)
	current.rootPart = nil

	if not MovementConfig.Control.Enabled then
		return
	end

	local timeout = MovementConfig.Control.SetupTimeoutSeconds
	local root = character:WaitForChild("HumanoidRootPart", timeout)
	local humanoid = character:WaitForChild("Humanoid", timeout)

	if token ~= current.characterToken then
		return
	end
	if root == nil or humanoid == nil or character.Parent == nil then
		return
	end
	if localPlayer.Character ~= character then
		return
	end

	-- Same resolver the server uses, on this client's copy of the same rig.
	local rig = RigOffset.measure(character)
	if rig.Source == "Fallback" then
		warn(string.format("[MinecraftClient] rig offset not measurable, using fallback: %s", RigOffset.describe(rig)))
	end
	-- Recorded for comparison only; the snapshot value is what presentation uses.
	current.localRootToFeetOffsetStuds = rig.Studs
	current.offsetMismatchWarned = false

	current.rootPart = root
	current.controller = takeClientControl(root, humanoid)
	current.ready = current.predicted ~= nil
end

local function onCharacterRemoving()
	current.characterToken += 1
	restoreClientController()
	resetPrediction()
	-- Teardown: drop held keys, suppression state, and press history so nothing
	-- from this body can drive the next one.
	InputController.reset(input, current.generation)
	current.rootPart = nil
	current.localRootToFeetOffsetStuds = nil
end

localPlayer.CharacterAdded:Connect(function(character)
	task.spawn(onCharacterAdded, character)
end)
localPlayer.CharacterRemoving:Connect(onCharacterRemoving)

if localPlayer.Character then
	task.spawn(onCharacterAdded, localPlayer.Character)
end

-- ===== Main loops =====

RunService.Heartbeat:Connect(function(dt)
	if not MovementConfig.Control.Enabled then
		return
	end
	if not current.ready or current.predicted == nil then
		return
	end

	local sim = MovementConfig.Simulation
	current.stepAccumulator += dt
	local steps = 0

	while current.stepAccumulator >= sim.TickDuration and steps < sim.MaxCatchUpTicks do
		current.stepAccumulator -= sim.TickDuration
		steps += 1
		stepClientTick()

		if current.awaitingResync then
			-- Stop predicting until the reset arrives; do not bank the backlog.
			current.stepAccumulator = 0
			break
		end
	end

	if steps >= sim.MaxCatchUpTicks then
		current.stepAccumulator = 0
	end
end)

RunService.RenderStepped:Connect(function(dt)
	if not MovementConfig.Control.Enabled then
		return
	end
	if not current.ready or current.predicted == nil or current.rootPart == nil then
		return
	end

	-- Presentation only: decay the residual between the old prediction and the
	-- reconciled one. It never feeds back into the simulation.
	local decay = math.exp(-MovementConfig.Prediction.OffsetDecayPerSecond * dt)
	current.offset *= decay
	if current.offset.Magnitude < 0.0005 then
		current.offset = Vector3.zero
	end

	current.rootPart.CFrame = MovementMath.toRootCFrame(
		current.predicted,
		current.rootToFeetOffsetStuds,
		current.offset
	)
end)

-- ===== Debug readout (presentation only) =====
-- Raw and processed axes are shown side by side on purpose: the debug view is
-- the quickest way to confirm the sneak multiplier is applied once, at input
-- collection, and that the 0.98 damping is not applied here.

local function flagText(value)
	return if value then "1" else "0"
end

local function debugLines()
	local frame = current.debugFrame or InputState.neutral(current.generation, 0, 0, 0, 0)
	local raw = input.Raw
	local ack = if current.predicted ~= nil then current.predicted.LastAppliedInputSeq else 0
	return {
		string.format(
			"input   gen %d  ready %s  suppressed %s",
			current.generation,
			tostring(current.ready),
			raw.SuppressedReason or "-"
		),
		string.format(
			"keys    W %s  S %s  A %s  D %s  Space %s  Shift %s  Ctrl %s",
			flagText(raw.Forward),
			flagText(raw.Back),
			flagText(raw.Left),
			flagText(raw.Right),
			flagText(raw.Jump),
			flagText(raw.Sneak),
			flagText(raw.Sprint)
		),
		string.format("raw     fwd %+.0f  str %+.0f", current.debugRawForward, current.debugRawStrafe),
		string.format("proc    fwd %+.3f  str %+.3f", frame.MoveForward, frame.MoveStrafe),
		string.format("flags   jump %s  sneak %s  sprint-req %s", flagText(frame.Jump), flagText(frame.Sneak), flagText(frame.Sprint)),
		string.format("look    yaw %+.1f  pitch %+.1f", frame.Yaw, frame.Pitch),
		string.format("taps    fwd presses %d  in window %d (no eligibility)", input.PressCount, input.HistoryDepth),
		string.format("net     seq %d  ack %d  pending %d", current.lastSentSeq, ack, #current.pending),
	}
end

RunService.RenderStepped:Connect(function(dt)
	if overlay == nil then
		return
	end
	InputDebugOverlay.update(overlay, dt, debugLines)
end)
