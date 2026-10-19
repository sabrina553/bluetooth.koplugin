-- How often to re-check the radio or a device after an action. Most toggles
-- have landed by the first check, so the early ones are quick; then it slows
-- to once a second. The total stays about 9 s, as with the old ten 1 s checks
-- (Sabrina, 2026-10-19: confirmations felt a touch slow).
local Poll = {}

local EARLY_DELAYS_S = { 0.25, 0.25, 0.5 }

Poll.MAX_ATTEMPTS = 12

--- Seconds to wait after check number `attempt` before the next one.
---@param attempt integer
---@return number
function Poll.delay(attempt)
    return EARLY_DELAYS_S[attempt] or 1
end

return Poll
