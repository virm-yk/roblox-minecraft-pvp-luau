--!nonstrict
-- InputDebugOverlay
-- Toggleable on-screen readout of the input pipeline. Presentation only: it
-- reads values the client already computed and never touches simulation state.
--
-- Toggle key comes from MovementConfig.Debug.ToggleKey (F3). The whole overlay
-- is skipped when MovementConfig.Debug.Enabled is false.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("MinecraftShared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))

local InputDebugOverlay = {}
InputDebugOverlay.__index = InputDebugOverlay

local LINE_HEIGHT = 15
local PANEL_WIDTH = 360
local MAX_LINES = 8

function InputDebugOverlay.new()
	local self = setmetatable({}, InputDebugOverlay)
	self.Visible = false
	self.Accumulator = 0
	self.Lines = {}
	self.Generation = 0
	self.LastResync = "none"

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "MovementDebug"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.BackgroundColor3 = Color3.new(0, 0, 0)
	panel.BackgroundTransparency = 0.35
	panel.BorderSizePixel = 0
	panel.Position = UDim2.new(0, 12, 0, 12)
	panel.Size = UDim2.new(0, PANEL_WIDTH, 0, LINE_HEIGHT * MAX_LINES + 8)
	panel.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "Readout"
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 6, 0, 4)
	label.Size = UDim2.new(1, -12, 1, -8)
	label.Font = Enum.Font.Code
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(230, 230, 230)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = ""
	label.Parent = panel

	self.Gui = gui
	self.Label = label

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == MovementConfig.Debug.ToggleKey then
			InputDebugOverlay.toggle(self)
		end
	end)

	return self
end

function InputDebugOverlay.toggle(self)
	self.Visible = not self.Visible
	self.Gui.Enabled = self.Visible
	if self.Visible then
		self.Label.Text = table.concat(self.Lines, "\n")
	end
end

function InputDebugOverlay.setLines(self, lines)
	self.Lines = lines
	if self.Visible then
		self.Label.Text = table.concat(lines, "\n")
	end
end

-- Rate-limited refresh, driven from the client's render loop.
function InputDebugOverlay.update(self, dt, buildLines)
	if not self.Visible then
		return
	end
	self.Accumulator += dt
	if self.Accumulator < MovementConfig.Debug.RefreshSeconds then
		return
	end
	self.Accumulator = 0
	InputDebugOverlay.setLines(self, buildLines())
end

function InputDebugOverlay.destroy(self)
	if self.Gui ~= nil then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

return InputDebugOverlay
