--!nonstrict
-- InputController
-- Roblox-side input gathering: key polling, focus/typing suppression, and the
-- raw -> processed boundary. Produces the InputFrame the client sends and
-- predicts with; owns no simulation state.
--
-- Split of responsibilities:
--   * This module touches Roblox input APIs and nothing else.
--   * InputState owns the pure conversion (cancellation, sneak scaling once).
--   * InputHistory owns the double-tap gesture record.
--   * MovementMath owns the per-tick 0.98 damping and moveFlying normalization,
--     both of which must NOT happen here.
--
-- Key state is POLLED once per simulation tick, mirroring 1.9's
-- KeyBinding.func_186704_a() -> Keyboard.isKeyDown sweep. Event-driven latching
-- is deliberately avoided: a missed InputEnded (window blur, GUI capture, chat)
-- would otherwise leave a key stuck down forever.

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MinecraftShared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local InputState = require(Shared:WaitForChild("InputState"))
local InputHistory = require(Shared:WaitForChild("InputHistory"))

local InputController = {}
InputController.__index = InputController

-- Roblox routes keystrokes to a focused TextBox (the chat bar is one) and stops
-- delivering them to the game. Both cases must suppress movement input.
local function isTextEntryFocused()
	local ok, focused = pcall(function()
		return UserInputService:GetFocusedTextBox()
	end)
	if not ok then
		return false
	end
	return focused ~= nil
end

function InputController.new()
	local self = setmetatable({}, InputController)

	self.Raw = InputState.newRaw()
	self.History = InputHistory.new(0)
	self.WindowFocused = true
	self.SuppressReason = nil
	self.SuppressedTicks = 0
	self.PollCount = 0
	-- Diagnostics: forward-key presses seen, and how many are still inside the
	-- double-tap window. The sprint stage reads History, not these counters.
	self.PressCount = 0
	self.HistoryDepth = 0

	UserInputService.WindowFocused:Connect(function()
		self.WindowFocused = true
		-- Nothing that was held across the blur may come back latched.
		InputState.clearRaw(self.Raw)
		InputHistory.reset(self.History, self.History.Generation)
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		self.WindowFocused = false
		InputState.suppress(self.Raw, "Unfocused")
		InputHistory.reset(self.History, self.History.Generation)
		self.SuppressReason = "Unfocused"
	end)

	return self
end

-- Reads the seven bound keys into Raw. Never writes processed values.
function InputController.poll(self)
	local reason = nil
	if not self.WindowFocused then
		reason = "Unfocused"
	elseif isTextEntryFocused() then
		reason = "Typing"
	end

	if reason ~= nil then
		InputState.suppress(self.Raw, reason)
		if self.SuppressReason ~= reason then
			-- Entering suppression is the unPressAllKeys() moment: drop any
			-- half-finished double tap so it cannot fire after typing.
			InputHistory.reset(self.History, self.History.Generation)
		end
		self.SuppressReason = reason
		self.SuppressedTicks += 1
		return
	end

	if self.SuppressReason ~= nil then
		-- Leaving suppression: keys must be re-pressed, not resumed.
		InputState.clearRaw(self.Raw)
		InputHistory.reset(self.History, self.History.Generation)
	end
	self.SuppressReason = nil
	InputState.suppress(self.Raw, nil)

	local keys = MovementConfig.Input.Keys
	local raw = self.Raw
	raw.Forward = UserInputService:IsKeyDown(keys.Forward)
	raw.Back = UserInputService:IsKeyDown(keys.Back)
	raw.Left = UserInputService:IsKeyDown(keys.Left)
	raw.Right = UserInputService:IsKeyDown(keys.Right)
	raw.Jump = UserInputService:IsKeyDown(keys.Jump)
	raw.Sneak = UserInputService:IsKeyDown(keys.Sneak)
	raw.Sprint = UserInputService:IsKeyDown(keys.Sprint)
	self.PollCount += 1
end

-- One call per simulation tick. Returns the processed frame plus the pre-scale
-- axes, which exist only for the debug readout.
function InputController.gather(self, generation, seq, clientTick, yaw, pitch)
	InputController.poll(self)

	if self.History.Generation ~= generation then
		InputHistory.reset(self.History, generation)
	end

	-- The gesture is recorded from raw key state, before scaling, because 1.9
	-- arms the sprint timer from the forward key edge itself.
	InputHistory.observe(self.History, self.Raw.Forward and not self.Raw.Suppressed, clientTick)

	local frame = InputState.process(self.Raw, generation, seq, clientTick, yaw, pitch)
	local rawForward, rawStrafe = InputState.rawAxes(self.Raw)
	self.PressCount = InputHistory.pressCount(self.History)
	self.HistoryDepth = InputHistory.bufferSize(self.History)
	return frame, rawForward, rawStrafe
end

-- Teardown / respawn: no held key, no stale double tap, no cross-generation
-- history may survive into the next body.
function InputController.reset(self, generation)
	InputState.clearRaw(self.Raw)
	InputHistory.reset(self.History, generation or 0)
	self.SuppressedTicks = 0
	self.PressCount = 0
	self.HistoryDepth = 0
end

function InputController.isSuppressed(self)
	return self.Raw.Suppressed
end

return InputController
