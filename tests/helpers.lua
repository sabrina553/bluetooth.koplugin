-- Shared by the tests that use the check(cond, message) style. Load with
-- package.path = "tests/?.lua;" .. package.path, run from the repo root.
local helpers = {}

--- A string here means a check(description, actual, expected) call from
--- the other test style, which would always pass (it did, 2026-10-26).
--- Level 3 points the error at the test line, not at check().
function helpers.rejectDescription(cond)
    if type(cond) == "string" then
        error("check(cond, message) called with a description first: " .. cond, 3)
    end
end

return helpers
