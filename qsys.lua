-- daily_quests/init.lua
local modname = minetest.get_current_modname()
local modpath = minetest.get_modpath(modname)
local storage = minetest.get_mod_storage()

-- CONFIG (tweak safely)
local MAX_QUESTS = 6               -- maximum quests given to a player
local MAX_REQUIRED = 10000         -- sanity cap for "required" amounts
local MAX_PROGRESS_PER_EVENT = 100 -- cap how much progress an event can add at once
local SAVE_DEBOUNCE = 2           -- seconds to debounce saves per player
local SAVE_RETRY = 3              -- retry times if save fails

-- internal caches & locks
local player_data = {}    -- in-memory data per player
local save_timers = {}    -- debounce timers
local save_locks = {}     -- simple save lock per player

-- Helper: safe deserialize with fallback
local function safe_deserialize(str)
    if not str or str == "" then return nil end
    local ok, val = pcall(minetest.deserialize, str)
    if ok and type(val) == "table" then
        return val
    end
    return nil
end

-- Default empty player structure
local function default_player_struct()
    return {
        quests = {},
        last_reset = "", -- ISO date string YYYY-MM-DD
    }
end

-- Load player data (robust)
local function load_player_data(name)
    local raw = storage:get_string(name) or ""
    local data = safe_deserialize(raw)
    if not data or type(data) ~= "table" then
        -- log corruption and reset
        minetest.log("warning", modname .. ": corrupted data for '" .. name .. "' - resetting")
        data = default_player_struct()
    end
    -- ensure structure validity
    data.quests = data.quests or {}
    data.last_reset = data.last_reset or ""
    return data
end

-- Internal immediate save (protected)
local function immediate_save(name)
    if not name then return false end
    if save_locks[name] then
        -- already saving; skip (will be re-scheduled by debounce)
        return false
    end
    save_locks[name] = true
    local ok, err = pcall(function()
        -- always reload existing storage to avoid clobbering other server-side edits
        local existing = safe_deserialize(storage:get_string(name) or "") or {}
        -- merge simple write: prefer in-memory data but keep unknown keys
        local towrite = existing
        towrite.quests = player_data[name].quests
        towrite.last_reset = player_data[name].last_reset
        storage:set_string(name, minetest.serialize(towrite))
    end)
    save_locks[name] = nil
    if not ok then
        minetest.log("error", modname .. ": failed to save data for " .. name .. " => " .. tostring(err))
        return false
    end
    return true
end

-- Debounced save (avoids spamming mod storage)
local function schedule_save(name)
    if save_timers[name] then
        -- already scheduled; let it run
        return
    end
    save_timers[name] = true
    minetest.after(SAVE_DEBOUNCE, function()
        save_timers[name] = nil
        -- try a few times if it fails
        local attempt = 0
        while attempt < SAVE_RETRY do
            if immediate_save(name) then return end
            attempt = attempt + 1
            -- small delay between retries
            minetest.sleep and minetest.sleep(0.1) -- if runtime supports, otherwise ignored
        end
        -- if we end up here, log permanent failure
        minetest.log("error", modname .. ": persistent save failure for " .. name)
    end)
end

-- Generate safe default quests (bounded)
local function generate_daily_quests()
    local function safe_quest(t)
        t.progress = 0
        t.required = math.max(1, math.min(t.required or 1, MAX_REQUIRED))
        return t
    end
    -- Example pool (extend as needed)
    local pool = {
        { id = "mine_stone", desc = "Mine 50 cobblestone", type = "dig", target = "default:cobble", required = 50, reward = "default:diamond 1" },
        { id = "kill_zombie", desc = "Kill 3 zombies", type = "kill", target = "mobs:zombie", required = 3, reward = "default:gold_ingot 1" },
        { id = "submit_apple", desc = "Submit 10 apples", type = "submit", target = "default:apple", required = 10, reward = "default:apple 5" },
        { id = "die_once", desc = "Die once (yes, seriously)", type = "die", target = "", required = 1, reward = "default:coal_lump 3" },
    }
    local quests = {}
    for i = 1, math.min(MAX_QUESTS, #pool) do
        local q = pool[i] -- simple deterministic selection for stability
        quests[#quests + 1] = safe_quest(table.copy and table.copy(q) or q)
    end
    return quests
end

-- Reset daily quests for a player
local function reset_daily_quests(name)
    if not name then return end
    player_data[name] = player_data[name] or default_player_struct()
    player_data[name].quests = generate_daily_quests()
    player_data[name].last_reset = os.date("%Y-%m-%d")
    schedule_save(name)
end

-- Ensure player's quests are up-to-date for the day
local function check_daily_reset(name)
    if not name then return end
    player_data[name] = player_data[name] or load_player_data(name)
    if player_data[name].last_reset ~= os.date("%Y-%m-%d") then
        reset_daily_quests(name)
    end
end

-- Safe incremental progress addition
local function add_progress_safe(name, qindex, amount)
    if not name or not player_data[name] then return end
    local q = player_data[name].quests[qindex]
    if not q then return end
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    -- cap increment
    amount = math.min(amount, MAX_PROGRESS_PER_EVENT)
    q.progress = (q.progress or 0) + amount
    q.progress = math.min(q.progress, q.required or MAX_REQUIRED)
    schedule_save(name)
end

-- Claim reward (safe)
local function claim_reward(player, qindex)
    local name = player:get_player_name()
    local data = player_data[name]
    if not data or not data.quests or not data.quests[qindex] then
        minetest.chat_send_player(name, "[Quests] That quest no longer exists.")
        return
    end
    local q = data.quests[qindex]
    if (q.progress or 0) < (q.required or 1) then
        minetest.chat_send_player(name, "[Quests] Quest not complete.")
        return
    end
    -- give reward in protected pcall
    local ok, err = pcall(function()
        local inv = player:get_inventory()
        if inv then
            inv:add_item("main", q.reward or "")
        end
    end)
    if not ok then
        minetest.log("error", modname .. ": failed to give reward to " .. name .. " => " .. tostring(err))
        minetest.chat_send_player(name, "[Quests] Error giving reward; contact admin.")
        return
    end
    -- mark reward claimed: simple behavior -> reset progress and make required harder (bounded)
    q.progress = 0
    q.required = math.min(MAX_REQUIRED, math.max(1, math.floor((q.required or 1) * 1.5)))
    schedule_save(name)
    minetest.chat_send_player(name, "[Quests] Reward claimed: " .. (q.reward or ""))
end

-- Build a safe formspec (avoids excessive length)
local function build_formspec(name)
    check_daily_reset(name)
    local data = player_data[name]
    local form = {"formspec_version[4]size[8,8]"}
    -- header
    form[#form+1] = ("label[0.5,0.4;Daily Quests — %s]"):format(minetest.formspec_escape(name))
    local y = 1.0
    for i, q in ipairs(data.quests) do
        if y > 7 then break end -- avoid overflowing formspec
        local prog = tostring(q.progress or 0) .. "/" .. tostring(q.required or 0)
        local done = (q.progress or 0) >= (q.required or 1) and "✅" or "⏳"
        form[#form+1] = ("label[0.5,%.1f;%s %s (%s)]"):format(y, minetest.formspec_escape(done), minetest.formspec_escape(q.desc or "Quest"), minetest.formspec_escape(prog))
        if (q.progress or 0) >= (q.required or 1) then
            form[#form+1] = ("button[6,%.1f;1.4,0.7;claim_%d;Claim]"):format(y - 0.3, i)
        end
        y = y + 0.8
    end
    form[#form+1] = "button[0.5,7.4;2,0.6;btn_refresh;Refresh]"
    return table.concat(form, "")
end

-- Show formspec (protected)
local function show_quests_formspec(player)
    if not player then return end
    local name = player:get_player_name()
    local ok, fs = pcall(build_formspec, name)
    if not ok then
        minetest.chat_send_player(name, "[Quests] Unable to open quests (internal error).")
        minetest.log("error", modname .. ": build_formspec failed for " .. name .. " => " .. tostring(fs))
        return
    end
    minetest.show_formspec(name, modname .. ":quests", fs)
end

-- Handle formspec events (protected)
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= modname .. ":quests" then return end
    local name = player:get_player_name()
    -- protect against missing data
    player_data[name] = player_data[name] or load_player_data(name)
    -- check all claim buttons and special buttons
    for k, _ in pairs(fields) do
        if k:match("^claim_(%d+)$") then
            local idx = tonumber(k:match("^claim_(%d+)$"))
            if idx then
                local ok, err = pcall(claim_reward, player, idx)
                if not ok then
                    minetest.log("error", modname .. ": claim_reward error for " .. name .. " => " .. tostring(err))
                    minetest.chat_send_player(name, "[Quests] Error claiming reward.")
                end
                return
            end
        end
    end
    if fields.btn_refresh then
        show_quests_formspec(player)
    end
end)

-- Safe event handlers wrapper
local function safe_handler(func)
    return function(...)
        local ok, err = pcall(func, ...)
        if not ok then
            minetest.log("error", modname .. ": handler error => " .. tostring(err))
        end
    end
end

-- Hook: on_dignode (dig progress)
minetest.register_on_dignode(safe_handler(function(pos, oldnode, digger)
    if not digger or not digger:is_player() or not oldnode or not oldnode.name then return end
    local name = digger:get_player_name()
    player_data[name] = player_data[name] or load_player_data(name)
    check_daily_reset(name)
    for i, q in ipairs(player_data[name].quests) do
        if q.type == "dig" and q.target == oldnode.name and (q.progress or 0) < (q.required or 0) then
            add_progress_safe(name, i, 1)
        end
    end
end))

-- Hook: on_punch to capture kills from some mob frameworks; best-effort only
minetest.register_on_punchplayer(safe_handler(function(player, hitter, time_from_last_punch, tool_caps, dir, damage)
    -- if a player was killed by a player, on_punchplayer is not always the right event.
    -- We primarily use on_punchplayer to detect melee kills of players (for "kill player" type quests).
    if not (player and hitter and hitter:is_player()) then return end
    -- do nothing here; actual kill detection handled in on_die below
end))

-- Hook: on_die to detect player deaths (and killer attributed if possible)
minetest.register_on_dieplayer(safe_handler(function(player)
    local name = player:get_player_name()
    player_data[name] = player_data[name] or load_player_data(name)
    check_daily_reset(name)
    for i, q in ipairs(player_data[name].quests) do
        if q.type == "die" and (q.progress or 0) < (q.required or 0) then
            add_progress_safe(name, i, 1)
        end
    end
    -- detect killer in last damage if registered by some mods is complicated; skip for stability
end))

-- Hook: globalstep or custom node for mob kills depends on mob mod; best-effort from register_on_punch/attack not reliable.
-- A robust integration should be implemented per mob API. For now add a helpful API function for other mods to call:
-- other mods can call: minetest.call_mod("daily_quests_add_kill", playername, target_name, amount)
minetest.register_chatcommand("quests", {
    description = "View your daily quests",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not online." end
        show_quests_formspec(player)
        return true
    end
})

-- Expose simple API for external integration (safe wrapper)
local function api_add_kill(name, target_name, amount)
    if not name then return false end
    player_data[name] = player_data[name] or load_player_data(name)
    check_daily_reset(name)
    for i, q in ipairs(player_data[name].quests) do
        if q.type == "kill" and q.target == target_name and (q.progress or 0) < (q.required or 0) then
            add_progress_safe(name, i, amount or 1)
        end
    end
    return true
end

-- register global function for other mods to call without pcall risk
rawset(_G, "daily_quests_add_kill", api_add_kill)

-- On player join/load
minetest.register_on_joinplayer(safe_handler(function(player)
    local name = player:get_player_name()
    player_data[name] = load_player_data(name)
    check_daily_reset(name)
    -- immediate save to ensure storage entry exists (debounced to not spam)
    schedule_save(name)
end))

-- On leave: flush immediate
minetest.register_on_leaveplayer(safe_handler(function(player)
    local name = player:get_player_name()
    -- attempt immediate save on leave to persist latest state
    if name and player_data[name] then
        immediate_save(name)
    end
    -- free memory
    player_data[name] = nil
end))

-- Clean startup log
minetest.log("action", modname .. " loaded (crash-hardened daily quest system).")
