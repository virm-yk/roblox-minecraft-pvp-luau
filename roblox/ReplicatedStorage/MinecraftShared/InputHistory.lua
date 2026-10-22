--!strict
-- InputHistory
-- Client-side record of forward-key press edges, exposed for the sprint stage.
--
-- It records a GESTURE and nothing else. Sprint ELIGIBILITY - grounded, food
-- level, blindness, using an item, collided horizontally, already sprinting -
-- is deliberately not implemented here, and none of this is ever sent to the
-- server: 1.9 decides sprint from the simulation, so history is client-local
-- input state only.
--
-- Timing reference: EntityPlayerSP.sprintToggleTimer (7 ticks). A fresh forward
-- press arms the timer; a second fresh press while it is still running starts
-- sprinting. This module exposes exactly the two edges that decision needs.
--
-- The buffer is bounded by the double-tap window: older presses cannot affect
-- the gesture, so they are dropped as the window advances.

local MovementConfig = require(script.Parent.MovementConfig)

local InputHistory = {}

export type History = {
	Generation: number,
	PressTicks: { number }, -- ascending client ticks of forward press edges
	LastForwardDown: boolean,
	LastTick: number,
	TotalPresses: number,
}

function InputHistory.new(generation: number): History
	return {
		Generation = generation,
		PressTicks = {},
		LastForwardDown = false,
		LastTick = -1,
		TotalPresses = 0,
	}
end

function InputHistory.reset(history: History, generation: number)
	history.Generation = generation
	history.PressTicks = {}
	history.LastForwardDown = false
	history.LastTick = -1
	history.TotalPresses = 0
end

-- Records an edge when forward transitions up->down. Ticks must be monotonic:
-- an equal or older tick is ignored, so re-gathering the same tick (or replaying
-- one) can never double-count a press. Returns true only for a fresh edge.
function InputHistory.observe(history: History, forwardDown: boolean, clientTick: number): boolean
	if clientTick <= history.LastTick then
		return false
	end
	history.LastTick = clientTick

	local pressed = false
	if forwardDown and not history.LastForwardDown then
		pressed = true
		history.TotalPresses += 1
		table.insert(history.PressTicks, clientTick)

		local window = MovementConfig.Input.DoubleTapWindowTicks
		while #history.PressTicks > 0 and clientTick - history.PressTicks[1] > window do
			table.remove(history.PressTicks, 1)
		end
	end

	history.LastForwardDown = forwardDown
	return pressed
end

-- True only on the tick that completed a double tap: the most recent press edge
-- happened this tick and an earlier edge is within the window. Pure gesture - no
-- eligibility check of any kind.
function InputHistory.doubleTapped(history: History, clientTick: number): boolean
	local count = #history.PressTicks
	if count < 2 then
		return false
	end
	if history.PressTicks[count] ~= clientTick then
		return false
	end
	return clientTick - history.PressTicks[count - 1] <= MovementConfig.Input.DoubleTapWindowTicks
end

function InputHistory.pressCount(history: History): number
	return history.TotalPresses
end

function InputHistory.bufferSize(history: History): number
	return #history.PressTicks
end

return InputHistory
