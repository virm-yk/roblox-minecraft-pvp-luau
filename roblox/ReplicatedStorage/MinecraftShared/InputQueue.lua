--!strict
-- InputQueue
-- Server-side input admission policy. Pure data + arithmetic: no Roblox APIs,
-- no networking, no movement.
--
-- Contract:
--   * One frame is consumed per server simulation tick, never more.
--   * Frames are applied strictly in Seq order, contiguously. A frame is only
--     applied when its Seq == LastAppliedSeq + 1.
--   * A gap does NOT get simulated and does NOT get skipped. Later frames wait
--     in the bounded queue until the missing frame arrives or the server resets.
--   * Queue overflow is reported, never silently evicted. The caller must reset
--     the session; dropping frames while continuing would desynchronise replay.
--   * Duplicate, stale, wrong-generation, and excessive-jump frames are rejected
--     without touching the queue.
--
-- `LastAppliedSeq` is the acknowledgement the server publishes in snapshots.

local MovementConfig = require(script.Parent.MovementConfig)
local InputState = require(script.Parent.InputState)

local InputQueue = {}

export type PushResult =
	"Accepted"
	| "Duplicate"
	| "Stale"
	| "WrongGeneration"
	| "GapTooLarge"
	| "Overflow"

export type TickResult = "Applied" | "Gap" | "Starved"

export type Queue = {
	Generation: number,
	LastAppliedSeq: number,
	Frames: { InputState.InputFrame },
	GapTicks: number,
	StarvedTicks: number,
	Pushed: number,
	Applied: number,
	Rejected: number,
	LastPushResult: PushResult?,
}

function InputQueue.new(generation: number): Queue
	return {
		Generation = generation,
		LastAppliedSeq = 0,
		Frames = {},
		GapTicks = 0,
		StarvedTicks = 0,
		Pushed = 0,
		Applied = 0,
		Rejected = 0,
		LastPushResult = nil,
	}
end

function InputQueue.reset(queue: Queue, generation: number)
	queue.Generation = generation
	queue.LastAppliedSeq = 0
	queue.Frames = {}
	queue.GapTicks = 0
	queue.StarvedTicks = 0
	queue.LastPushResult = nil
end

function InputQueue.depth(queue: Queue): number
	return #queue.Frames
end

function InputQueue.minQueuedSeq(queue: Queue): number?
	local first = queue.Frames[1]
	return first ~= nil and first.Seq or nil
end

function InputQueue.gapExceeded(queue: Queue): boolean
	-- GapTicks is the number of consecutive ticks already spent waiting.
	return queue.GapTicks >= MovementConfig.InputQueue.GapWaitTicks
end

function InputQueue.starving(queue: Queue): boolean
	return queue.StarvedTicks > MovementConfig.InputQueue.StarveWarnTicks
end

function InputQueue.idleTimedOut(queue: Queue): boolean
	return queue.StarvedTicks > MovementConfig.InputQueue.IdleTimeoutTicks
end

function InputQueue.push(queue: Queue, frame: InputState.InputFrame): PushResult
	local result: PushResult

	if frame.Generation ~= queue.Generation then
		result = "WrongGeneration"
	elseif frame.Seq <= queue.LastAppliedSeq then
		result = "Stale"
	elseif frame.Seq > queue.LastAppliedSeq + MovementConfig.InputQueue.MaxSequenceJump then
		result = "GapTooLarge"
	else
		-- Duplicate detection must run before the capacity check, so a repeated
		-- frame is reported as a duplicate rather than as queue overflow.
		local duplicate = false
		for _, queued in ipairs(queue.Frames) do
			if queued.Seq == frame.Seq then
				duplicate = true
				break
			end
		end

		if duplicate then
			result = "Duplicate"
		elseif #queue.Frames >= MovementConfig.InputQueue.MaxQueued then
			-- Never evict a queued frame: the caller must reset instead.
			result = "Overflow"
		else
			result = "Accepted"
			local inserted = false
			for index, queued in ipairs(queue.Frames) do
				if queued.Seq > frame.Seq then
					table.insert(queue.Frames, index, frame)
					inserted = true
					break
				end
			end
			if not inserted then
				table.insert(queue.Frames, frame)
			end
		end
	end

	queue.LastPushResult = result
	if result == "Accepted" then
		queue.Pushed += 1
	else
		queue.Rejected += 1
	end
	return result
end

-- Consumes at most one frame. The caller runs exactly one movement step per
-- call, whether or not a frame was returned.
function InputQueue.consume(queue: Queue): (InputState.InputFrame?, TickResult)
	local first = queue.Frames[1]

	if first ~= nil and first.Seq == queue.LastAppliedSeq + 1 then
		table.remove(queue.Frames, 1)
		queue.LastAppliedSeq = first.Seq
		queue.GapTicks = 0
		queue.StarvedTicks = 0
		queue.Applied += 1
		return first, "Applied"
	end

	queue.StarvedTicks += 1
	if first ~= nil then
		-- A later frame is queued but the next contiguous one is missing.
		queue.GapTicks += 1
		return nil, "Gap"
	end

	queue.GapTicks = 0
	return nil, "Starved"
end

function InputQueue.stats(queue: Queue): { [string]: number }
	return {
		Generation = queue.Generation,
		LastAppliedSeq = queue.LastAppliedSeq,
		Depth = #queue.Frames,
		GapTicks = queue.GapTicks,
		StarvedTicks = queue.StarvedTicks,
		Pushed = queue.Pushed,
		Applied = queue.Applied,
		Rejected = queue.Rejected,
	}
end

return InputQueue
