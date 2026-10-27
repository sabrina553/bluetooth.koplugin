-- How often to re-check the radio or a device after an action. Most toggles
-- have landed by the first check, so the early ones are quick; then it slows
-- to once a second. The total stays about 9 s, as with the old ten 1 s checks
-- (decision 2026-10-19: confirmations felt a touch slow).
local Poll = {}

local EARLY_DELAYS_S = { 0.25, 0.25, 0.5 }

Poll.MAX_ATTEMPTS = 12

-- Pairing a phone waits for someone to tap "Pair" on it, so its confirm
-- runs about as long as the agent session (bluez.PAIR_SESSION_S, 20 s).
Poll.PAIR_ATTEMPTS = 24

--- Seconds to wait after check number `attempt` before the next one.
---@param attempt integer
---@return number
function Poll.delay(attempt)
    return EARLY_DELAYS_S[attempt] or 1
end

return Poll
