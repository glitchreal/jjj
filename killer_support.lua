-- Vichop killer: joins claimed Vicious Bee servers, tracks rewards, and can
-- post a Discord webhook summary after each confirmed kill.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local StarterGui = game:GetService("StarterGui")

local DATABASE_URL = "https://bss-job-queue-7bf75-default-rtdb.firebaseio.com"
local POLL_SECONDS = 4
local AFTER_JOIN_SETTLE_SECONDS = 8
local KILL_CHECK_SECONDS = 2
local REWARD_SETTLE_SECONDS = 3
local STALE_AFTER_SECONDS = 900

-- Set getgenv().VICHOP_WEBHOOK_URL in your loader to enable kill reports.
local DISCORD_WEBHOOK_URL = (getgenv and getgenv().VICHOP_WEBHOOK_URL) or ""
local WEBHOOK_USERNAME = "Vichop Tracker"
local WEBHOOK_AVATAR_URL = ""
local STATS_FILE = "vichop_stats.json"

local PLAYER = Players.LocalPlayer
local KILLER_NAME = PLAYER and PLAYER.Name or "killer"
local httpRequest = request or http_request or (syn and syn.request)
assert(type(httpRequest) == "function", "No executor HTTP request function found")

local function now()
    return os.time()
end

local function defaultStats()
    return {
        totalKills = 0, totalStingers = 0, totalJoins = 0,
        sessionKills = 0, sessionStingers = 0, sessionJoins = 0,
        startedAt = now(), updatedAt = now(),
    }
end

local function loadStats()
    if type(isfile) ~= "function" or type(readfile) ~= "function" or not isfile(STATS_FILE) then
        return defaultStats()
    end
    local ok, saved = pcall(function()
        return HttpService:JSONDecode(readfile(STATS_FILE))
    end)
    if not ok or type(saved) ~= "table" then
        return defaultStats()
    end
    local stats = defaultStats()
    for key, value in pairs(saved) do
        stats[key] = value
    end
    stats.sessionKills, stats.sessionStingers, stats.sessionJoins = 0, 0, 0
    stats.startedAt = now()
    return stats
end

local stats = loadStats()

local function saveStats()
    stats.updatedAt = now()
    if type(writefile) ~= "function" then
        return
    end
    local ok, err = pcall(function()
        writefile(STATS_FILE, HttpService:JSONEncode(stats))
    end)
    if not ok then
        warn("Could not save Vichop stats:", tostring(err))
    end
end

local function formatNumber(value)
    local text = tostring(math.floor(tonumber(value) or 0))
    return text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function notify(title, text)
    print("[Vichop] " .. title .. " - " .. text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 5 })
    end)
end

local function firebase(method, path, body)
    local response = httpRequest({
        Url = DATABASE_URL .. path,
        Method = method,
        Headers = { ["Content-Type"] = "application/json" },
        Body = body and HttpService:JSONEncode(body) or nil,
    })
    local status = response.StatusCode or response.status_code or response.Status or 0
    local responseBody = response.Body or response.body or ""
    if status < 200 or status >= 300 then
        warn("Firebase request failed", method, path, status, responseBody)
        return nil
    end
    if responseBody == "" or responseBody == "null" then
        return nil
    end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(responseBody)
    end)
    return ok and decoded or nil
end

local function getStingers()
    local coreStats = PLAYER and PLAYER:FindFirstChild("CoreStats")
    local stingers = coreStats and coreStats:FindFirstChild("Stingers")
    if stingers and (stingers:IsA("IntValue") or stingers:IsA("NumberValue")) then
        return tonumber(stingers.Value) or 0
    end
    return nil
end

local function viciousExists()
    local monsters = workspace:FindFirstChild("Monsters")
    if not monsters then
        return false, nil
    end
    for _, monster in ipairs(monsters:GetChildren()) do
        if monster:IsA("Model") then
            local monsterType = monster:FindFirstChild("MonsterType")
            local humanoid = monster:FindFirstChildOfClass("Humanoid")
            local typeName = monsterType and tostring(monsterType.Value) or monster.Name
            if string.find(string.lower(typeName), "vicious bee", 1, true)
                and (not humanoid or humanoid.Health > 0) then
                return true, monster:GetFullName()
            end
        end
    end
    return false, nil
end

local hud = {}
local function createHud()
    if not Drawing or type(Drawing.new) ~= "function" then
        return
    end
    hud.background = Drawing.new("Square")
    hud.background.Color, hud.background.Transparency, hud.background.Filled = Color3.fromRGB(12, 16, 25), 0.2, true
    hud.background.Size, hud.background.Position, hud.background.Visible = Vector2.new(250, 132), Vector2.new(18, 210), true
    hud.accent = Drawing.new("Square")
    hud.accent.Color, hud.accent.Transparency, hud.accent.Filled = Color3.fromRGB(255, 190, 55), 0, true
    hud.accent.Size, hud.accent.Position, hud.accent.Visible = Vector2.new(4, 132), Vector2.new(18, 210), true
    hud.title = Drawing.new("Text")
    hud.title.Color, hud.title.Size, hud.title.Font, hud.title.Position, hud.title.Visible = Color3.fromRGB(255, 218, 112), 18, 2, Vector2.new(34, 220), true
    hud.body = Drawing.new("Text")
    hud.body.Color, hud.body.Size, hud.body.Font, hud.body.Position, hud.body.Visible = Color3.fromRGB(225, 231, 240), 15, 2, Vector2.new(34, 248), true
end

local function updateHud(state, detail)
    if not hud.title then
        return
    end
    hud.title.Text = "VICHOP  |  " .. (state or "SEARCHING")
    hud.body.Text = string.format(
        "Kills       %s  (session %s)\nStingers    %s  (session %s)\nJoins       %s  (session %s)\nUptime      %s\n%s",
        formatNumber(stats.totalKills), formatNumber(stats.sessionKills),
        formatNumber(stats.totalStingers), formatNumber(stats.sessionStingers),
        formatNumber(stats.totalJoins), formatNumber(stats.sessionJoins),
        formatDuration(now() - stats.startedAt), detail or "Polling queue"
    )
end

local function sendWebhook(stingersGained, jobId)
    if DISCORD_WEBHOOK_URL == "" then
        return
    end
    local payload = {
        username = WEBHOOK_USERNAME,
        avatar_url = WEBHOOK_AVATAR_URL ~= "" and WEBHOOK_AVATAR_URL or nil,
        embeds = {{
            title = "Vicious Bee eliminated",
            color = 16762429,
            fields = {
                { name = "Killer", value = "`" .. KILLER_NAME .. "`", inline = true },
                { name = "Stingers gained", value = "`+" .. formatNumber(stingersGained) .. "`", inline = true },
                { name = "Session kills", value = "`" .. formatNumber(stats.sessionKills) .. "`", inline = true },
                { name = "Total kills", value = "`" .. formatNumber(stats.totalKills) .. "`", inline = true },
                { name = "Total stingers", value = "`" .. formatNumber(stats.totalStingers) .. "`", inline = true },
                { name = "Server", value = "`" .. tostring(jobId):sub(1, 18) .. "...`", inline = false },
            },
            footer = { text = "Vichop Tracker | " .. formatDuration(now() - stats.startedAt) .. " session uptime" },
        }},
    }
    task.spawn(function()
        local response = httpRequest({
            Url = DISCORD_WEBHOOK_URL, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" }, Body = HttpService:JSONEncode(payload),
        })
        local status = response.StatusCode or response.status_code or response.Status or 0
        if status < 200 or status >= 300 then
            warn("Discord webhook failed:", status, response.Body or response.body or "")
        end
    end)
end

local function getOldestSpawnedJob()
    local data = firebase("GET", '/jobs.json?orderBy="status"&equalTo="spawned"&limitToFirst=20')
    local bestKey, bestJob = nil, nil
    for key, job in pairs(data or {}) do
        local age = now() - tonumber(job.updatedAt or job.createdAt or 0)
        if tonumber(job.placeId) == game.PlaceId and job.jobId ~= game.JobId and age >= 0 and age <= STALE_AFTER_SECONDS then
            if not bestJob or tonumber(job.createdAt or 0) < tonumber(bestJob.createdAt or 0) then
                bestKey, bestJob = key, job
            end
        elseif age > STALE_AFTER_SECONDS then
            print("Ignoring stale Vicious job:", key, "age:", age)
        end
    end
    return bestKey, bestJob
end

local function markJob(key, status, extra)
    local payload = extra or {}
    payload.status, payload.updatedAt = status, now()
    firebase("PATCH", "/jobs/" .. key .. ".json", payload)
end

local function recordKill(jobId, stingersBefore)
    task.wait(REWARD_SETTLE_SECONDS)
    local stingersAfter = getStingers()
    local gained = math.max(0, (stingersAfter or stingersBefore or 0) - (stingersBefore or stingersAfter or 0))
    stats.totalKills, stats.sessionKills = (tonumber(stats.totalKills) or 0) + 1, (tonumber(stats.sessionKills) or 0) + 1
    stats.totalStingers, stats.sessionStingers = (tonumber(stats.totalStingers) or 0) + gained, (tonumber(stats.sessionStingers) or 0) + gained
    saveStats()
    markJob(jobId, "killed", {
        killer = KILLER_NAME, killedInJobId = game.JobId, stingersGained = gained,
        killerTotalKills = stats.totalKills, killerTotalStingers = stats.totalStingers,
    })
    updateHud("KILL CONFIRMED", "+" .. formatNumber(gained) .. " stingers")
    notify("Vicious eliminated", "+" .. formatNumber(gained) .. " stingers | " .. formatNumber(stats.sessionKills) .. " session kills")
    sendWebhook(gained, jobId)
end

local function handleCurrentClaim()
    local currentJob = firebase("GET", "/jobs/" .. game.JobId .. ".json")
    if not currentJob or currentJob.status ~= "claimed" then
        return false
    end
    markJob(game.JobId, "claimed", { killer = KILLER_NAME, joinedJobId = game.JobId })
    updateHud("HUNTING", "Waiting for Vicious Bee")
    notify("Vichop joined", "Tracking the claimed Vicious server")
    task.wait(AFTER_JOIN_SETTLE_SECONDS)
    local stingersBefore = getStingers()
    while task.wait(KILL_CHECK_SECONDS) do
        local exists = viciousExists()
        if not exists then
            recordKill(game.JobId, stingersBefore)
            return true
        end
        updateHud("HUNTING", "Vicious Bee active")
    end
end

createHud()
updateHud("STARTING", "Checking this server")
print("Vichop killer running from JobId:", game.JobId)
handleCurrentClaim()

while task.wait(POLL_SECONDS) do
    local key, job = getOldestSpawnedJob()
    if key and job then
        stats.totalJoins, stats.sessionJoins = (tonumber(stats.totalJoins) or 0) + 1, (tonumber(stats.sessionJoins) or 0) + 1
        saveStats()
        markJob(key, "claimed", { killer = KILLER_NAME, claimedAt = now() })
        updateHud("TELEPORTING", "Claimed a Vicious server")
        notify("Vichop found", "Joining a Vicious Bee server")
        task.wait(1)
        TeleportService:TeleportToPlaceInstance(tonumber(job.placeId), tostring(job.jobId), PLAYER)
        break
    end
    updateHud("SEARCHING", "No active Vicious jobs")
end
