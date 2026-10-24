--!nonstrict
-- MinecraftServer
-- Server entry point. Responsibilities:
--   * create the RemoteEvents (names are part of the existing Explorer contract)
--   * own one authoritative Session per player
--   * admit validated input frames into a bounded, sequence-ordered queue
--   * run EXACTLY ONE movement step per session per authoritative ServerTick
--   * send snapshots that identify authoritative time and acknowledged input
--   * recover with an explicit generation reset when state or history is invalid
--   * keep the static collision world current when workspace.World changes
--   * resolve the rig's root-to-feet offset from the live character
--
-- CLOCKS: Seq is an input counter and ServerTick is simulation time. They are
-- different clocks (see MovementConfig) and this script never compares them.
--
-- Combat is disabled at this stage (CombatConfig.Enabled == false). The attack
-- remotes are still created so the client contract and Explorer layout are stable.
--
-- No movement or combat formulas live here.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MinecraftShared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local MovementState = require(Shared:WaitForChild("MovementState"))
local MovementMath = require(Shared:WaitForChild("MovementMath"))
local CollisionAdapter = require(Shared:WaitForChild("CollisionAdapter"))
local InputState = require(Shared:WaitForChild("InputState"))
local InputQueue = require(Shared:WaitForChild("InputQueue"))
local CombatConfig = require(Shared:WaitForChild("CombatConfig"))
local RigOffset = require(Shared:WaitForChild("RigOffset"))

-- ===== Networking setup =====

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local remotesFolder = getOrCreate(Shared, "Folder", MovementConfig.Remotes.Folder)
local inputRemote = getOrCreate(remotesFolder, "RemoteEvent", MovementConfig.Remotes.Input)
local stateRemote = getOrCreate(remotesFolder, "RemoteEvent", MovementConfig.Remotes.State)
local attackRemote = getOrCreate(remotesFolder, "RemoteEvent", CombatConfig.Remotes.Attack)
local combatResultRemote = getOrCreate(remotesFolder, "RemoteEvent", CombatConfig.Remotes.Result)

-- ===== Static collision world =====
-- Registered geometry is still static (anchored parts only), but the place can
-- change: the adapter watches workspace.World and swaps in a freshly built
-- world, so an empty startup world is never permanent and no box is ever
-- registered twice. Sessions read collision.World at step time; nothing caches
-- the reference. Movement integration is still disabled.

local collision = CollisionAdapter.watch({ Strict = false })

-- ===== Authoritative clock and sessions =====

local sessions = {}
local serverTick = 0
local generationCounter = 0
local setupTokens = {}

local function isInteger(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

local function consumeRate(session, key, limitPerSecond)
	local now = os.clock()
	local window = session.RateWindows[key]
	if not window or now - window.Start >= 1 then
		window = { Start = now, Count = 0 }
		session.RateWindows[key] = window
	end
	window.Count += 1
	return window.Count <= limitPerSecond
end

-- ===== Snapshot =====

local function sendSnapshot(session, reset, kind)
	stateRemote:FireClient(session.Player, {
		SchemaVersion = MovementConfig.SchemaVersion,
		Generation = session.Generation,
		ServerTick = session.State.ServerTick,
		LastAppliedInputSeq = session.State.LastAppliedInputSeq,
		-- The client presents with this exact value, so a local rig difference
		-- can never make the two sides fight over the root height.
		RootToFeetOffsetStuds = session.RootToFeetOffsetStuds,
		Reset = reset == true,
		ResetKind = kind,
		Health = session.State.Health,
		State = MovementState.toSnapshot(session.State),
	})
end

-- ===== Character controller ownership (symmetric with the client) =====

local function restoreController(record)
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

local function takeControl(root, humanoid)
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

local function applyStateToCharacter(session)
	if not MovementConfig.Control.Enabled then
		return
	end
	local character = session.Character
	if character == nil or character ~= session.Player.Character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root.Parent ~= nil then
		root.CFrame = MovementMath.toRootCFrame(session.State, session.RootToFeetOffsetStuds)
	end
end

-- ===== Session lifecycle =====

local function teardownSession(player)
	local session = sessions[player]
	if session == nil then
		return
	end
	sessions[player] = nil
	restoreController(session.Controller)
end

-- Explicit reset: preserve the last known-good state, advance the generation,
-- clear all input history, and tell the client to adopt the new generation.
local function requestResync(session, reason)
	if serverTick - session.LastResyncTick < MovementConfig.Server.ResyncCooldownTicks then
		return false
	end
	session.LastResyncTick = serverTick

	generationCounter += 1
	session.Generation = generationCounter

	local state = MovementState.clone(session.LastGoodState)
	state.Generation = session.Generation
	state.ServerTick = serverTick
	state.LastAppliedInputSeq = 0
	session.State = state
	session.LastGoodState = MovementState.clone(state)
	session.LastGoodTick = serverTick

	session.Queue = InputQueue.new(session.Generation)
	session.LastInput = nil
	session.Stale = false

	applyStateToCharacter(session)
	sendSnapshot(session, true, reason)
	return true
end

local function createSession(player, character)
	setupTokens[player] = (setupTokens[player] or 0) + 1
	local token = setupTokens[player]

	if not MovementConfig.Control.Enabled then
		return
	end
	if character == nil or character.Parent == nil then
		return
	end

	local timeout = MovementConfig.Control.SetupTimeoutSeconds
	local root = character:WaitForChild("HumanoidRootPart", timeout)
	local humanoid = character:WaitForChild("Humanoid", timeout)

	-- The character may have been replaced, removed, or disconnected while we
	-- were yielding. Every check below must pass before touching shared state.
	if token ~= setupTokens[player] then
		return
	end
	if root == nil or humanoid == nil then
		return
	end
	if root.Parent == nil or humanoid.Parent == nil then
		return
	end
	if player.Parent == nil or player.Character ~= character then
		return
	end

	teardownSession(player)

	-- Measure the rig the character actually has. HipHeight and root Size are
	-- replicated, so the client resolves the same value independently; the
	-- simulation itself stays in blocks and never sees these studs.
	local rig = RigOffset.measure(character)
	if rig.Source == "Fallback" then
		warn(
			string.format(
				"[MinecraftServer] %s: rig offset not measurable, using fallback: %s",
				player.Name,
				RigOffset.describe(rig)
			)
		)
	end

	generationCounter += 1
	local generation = generationCounter
	local spawnFeet = MovementMath.rootStudsToFeetBlocks(root.Position, rig.Studs)
	local state = MovementState.spawn(
		spawnFeet,
		generation,
		serverTick,
		CombatConfig.Health.MaxHealth,
		CombatConfig.DefaultWeaponId
	)

	local session = {
		Player = player,
		Character = character,
		Generation = generation,
		State = state,
		LastGoodState = MovementState.clone(state),
		LastGoodTick = serverTick,
		Queue = InputQueue.new(generation),
		LastInput = nil,
		Stale = false,
		LastResyncTick = -math.huge,
		Controller = takeControl(root, humanoid),
		-- Resolved once per character. Changing it later would need a re-measure
		-- and a snapshot reset; not done in this baseline.
		RootToFeetOffsetStuds = rig.Studs,
		RigOffsetSource = rig.Source,
		RigOffsetDetail = rig.Detail,
		RateWindows = {},
		-- Diagnostics only, never trusted by logic.
		MalformedInputs = 0,
		StaleInputs = 0,
		InvalidStates = 0,
	}

	sessions[player] = session

	-- The first snapshot is always a reset. The client adopts the generation
	-- from it and only then begins sending input.
	sendSnapshot(session, true, "Spawn")
	applyStateToCharacter(session)
end

-- ===== One authoritative movement step per session per server tick =====

local function simulateSession(session)
	if session.Stale then
		return
	end

	local frame, status = InputQueue.consume(session.Queue)

	if status ~= "Applied" then
		if InputQueue.gapExceeded(session.Queue) then
			requestResync(session, "InputGap")
			return
		end
		if InputQueue.idleTimedOut(session.Queue) then
			-- No applicable input for too long. Stop stepping rather than
			-- inventing a player who keeps walking; resume requires a reset.
			session.Stale = true
			return
		end
		if session.LastInput ~= nil then
			frame = InputState.starved(session.LastInput)
		else
			frame = InputState.idle(session.Generation, session.State.Yaw, session.State.Pitch)
		end
	else
		session.LastInput = frame
	end

	-- collision.World is looked up per step on purpose: a rebuild replaces it.
	local nextState = MovementMath.step(session.State, frame, collision.World, serverTick)

	if not MovementState.isPlausible(nextState) then
		session.InvalidStates += 1
		requestResync(session, "InvalidState")
		return
	end

	session.State = nextState
	session.LastGoodState = MovementState.clone(nextState)
	session.LastGoodTick = serverTick

	applyStateToCharacter(session)

	if serverTick % MovementConfig.Server.StateSnapshotIntervalTicks == 0 then
		sendSnapshot(session, false, nil)
	end
end

-- ===== Input handling (untrusted) =====

inputRemote.OnServerEvent:Connect(function(player, raw)
	local session = sessions[player]
	if session == nil or not MovementConfig.Control.Enabled then
		return
	end
	if type(raw) ~= "table" then
		return
	end

	local kind = raw.Kind

	if kind == "Resync" then
		if not consumeRate(session, "Resync", MovementConfig.Network.MaxResyncMessagesPerSecond) then
			return
		end
		if not isInteger(raw.Generation) or raw.Generation ~= session.Generation then
			return
		end
		requestResync(session, "ClientResync")
		return
	end

	if kind ~= "Input" then
		return
	end

	if not consumeRate(session, "Input", MovementConfig.Network.MaxInputMessagesPerSecond) then
		return
	end

	local frame = InputState.sanitize(raw)
	if frame == nil then
		session.MalformedInputs += 1
		return
	end

	if frame.Generation ~= session.Generation then
		-- Delayed packet from a previous character/session. Never apply it.
		session.StaleInputs += 1
		return
	end

	local result = InputQueue.push(session.Queue, frame)

	if result == "Accepted" then
		if session.Stale then
			-- Input returned after the idle timeout. Resume only through a reset
			-- so the client and server restart from the same acknowledged point.
			requestResync(session, "ResumeAfterIdle")
		end
	elseif result == "Overflow" then
		-- Dropping frames while continuing would make replay impossible.
		requestResync(session, "InputQueueOverflow")
	elseif result == "GapTooLarge" then
		requestResync(session, "SequenceJump")
	end
	-- Duplicate / Stale / WrongGeneration: counted by the queue, not fatal.
end)

-- ===== Attacks (disabled at this stage) =====

attackRemote.OnServerEvent:Connect(function(player, _payload)
	if not CombatConfig.Enabled then
		combatResultRemote:FireClient(player, { Accepted = false, Reason = "CombatDisabled" })
		return
	end
	-- The 1.9 combat pipeline is rebuilt in the combat stage.
	combatResultRemote:FireClient(player, { Accepted = false, Reason = "CombatNotImplemented" })
end)

-- ===== Fixed-tick authoritative simulation =====

local tickAccumulator = 0

RunService.Heartbeat:Connect(function(dt)
	local sim = MovementConfig.Simulation
	tickAccumulator += dt
	local steps = 0

	while tickAccumulator >= sim.TickDuration and steps < sim.MaxCatchUpTicks do
		tickAccumulator -= sim.TickDuration
		steps += 1
		serverTick += 1

		-- Exactly one step per session per tick. Packet frequency is irrelevant
		-- here: the queue is consulted once and yields at most one frame.
		for _, session in pairs(sessions) do
			simulateSession(session)
		end
	end

	if steps >= sim.MaxCatchUpTicks then
		tickAccumulator = 0 -- drop the backlog instead of spiralling
	end
end)

-- ===== Player lifecycle =====

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(createSession, player, character)
	end)

	player.CharacterRemoving:Connect(function()
		-- Invalidate any in-flight setup before dropping the session.
		setupTokens[player] = (setupTokens[player] or 0) + 1
		teardownSession(player)
	end)

	if player.Character ~= nil then
		task.spawn(createSession, player, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	setupTokens[player] = (setupTokens[player] or 0) + 1
	teardownSession(player)
	setupTokens[player] = nil
end)
