-- Daily Quests (Crash-proof base)
local modname = minetest.get_current_modname()
local modpath = minetest.get_modpath(modname)

daily_quests = {}

-- ===== Safe persistent storage =====
local storage = minetest.get_mod_storage()

local function load_player_data(name)
    local str = storage:get_string(name)
    if str == "" then
        return {submitted = false, kills = 0, deaths = 0, last_reset = ""}
    end
    local ok, data = pcall(minetest.deserialize, str)
    if not ok or type(data) ~= "table" then
        return {submitted = false, kills = 0, deaths = 0, last_reset = ""}
    end
    return data
end

local function save_player_data(name, data)
    local ok, err = pcall(function()
        storage:set_string(name, minetest.serialize(data))
    end)
    if not ok then
        minetest.log("error", "[daily_quests] Failed to save "..name..": "..tostring(err))
    end
end

-- ===== Quests system =====
local function reset_quests(name)
    local data = {
        submitted = false,
        kills = 0,
        deaths = 0,
        last_reset = os.date("%Y-%m-%d")
    }
    save_player_data(name, data)
    return data
end

local function get_daily_quest(name)
    local data = load_player_data(name)
    if data.last_reset ~= os.date("%Y-%m-%d") then
        data = reset_quests(name)
    end
    return data
end

-- ===== GUI =====
local function show_formspec(name)
    local player = minetest.get_player_by_name(name)
    if not player then return end

    local data = get_daily_quest(name)
    local fs = table.concat({
        "formspec_version[4]size[8,7]",
        "label[0.3,0.3;Daily Quest for: ", name, "]",
        "label[0.5,1.2;Kills: ", data.kills, "]",
        "label[0.5,1.7;Deaths: ", data.deaths, "]",
        "button[0.5,3;3,0.8;submit;Submit Items]",
        "button_exit[0.5,4;3,0.8;close;Close]"
    })

    local ok, err = pcall(function()
        minetest.show_formspec(name, modname .. ":main", fs)
    end)
    if not ok then
        minetest.log("error", "[daily_quests] Failed to show formspec: " .. tostring(err))
    end
end

-- ===== Chat command =====
minetest.register_chatcommand("quests", {
    description = "Show your daily quests",
    func = function(name)
        local ok, err = pcall(function() show_formspec(name) end)
        if not ok then
            minetest.chat_send_player(name, "Error opening quests: " .. tostring(err))
        end
        return true
    end
})

-- ===== Safe event hooks =====
minetest.register_on_dieplayer(function(player)
    local name = player and player:get_player_name()
    if not name then return end
    local data = get_daily_quest(name)
    data.deaths = (data.deaths or 0) + 1
    save_player_data(name, data)
end)

minetest.register_on_punchplayer(function(player, hitter)
    if not hitter or not hitter:is_player() then return end
    local name = hitter:get_player_name()
    if not name then return end
    local data = get_daily_quest(name)
    data.kills = (data.kills or 0) + 1
    save_player_data(name, data)
end)

-- ===== On join (auto reset daily) =====
minetest.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    if not name then return end
    local data = get_daily_quest(name)
    if data.last_reset ~= os.date("%Y-%m-%d") then
        reset_quests(name)
    end
end)

minetest.log("action", "[daily_quests] Loaded successfully (crash-proof base).")
