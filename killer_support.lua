-- Vichop killer: atomically claims live Vicious Bee jobs, confirms real deaths,
-- settles the live stinger reward, and reports one outcome per claimed event.

local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local BSS_PLACE_ID = 1537690962
local DATABASE_URL = "https://vichop-coordination-2026-default-rtdb.firebaseio.com"
local STATS_FILE = "vichop_stats.json"
local QUEUE_POLL_SECONDS = 0.75
local ARRIVAL_WAIT_SECONDS = 15
local HUNT_POLL_SECONDS = 0.1
local MAX_HUNT_SECONDS = 10 * 60
local REWARD_POLL_SECONDS = 0.4
local REWARD_MAX_SECONDS = 8
local REWARD_STABLE_READS = 3
local JOB_FRESH_SECONDS = 25
local CLAIM_LEASE_SECONDS = 30
local CLAIM_HEARTBEAT_SECONDS = 5
local CLEANUP_INTERVAL_SECONDS = 30
local TERMINAL_RETENTION_SECONDS = 60 * 60
local HTTP_TIMEOUT_SECONDS = 15
local TELEPORT_TIMEOUT_SECONDS = 7
local TELEPORT_RETRIES = 5
local SLOT_HANDOFF_TIMEOUT_SECONDS = 30
local SLOT_HANDOFF_POLL_SECONDS = 0.5
local ARRIVAL_COORDINATION_RETRY_SECONDS = 30
local MAX_WRONG_SERVER_REDIRECTS = 3
local SESSION_RESUME_MAX_AGE_SECONDS = 20 * 60
local ACTIVE_SEARCHER_TTL_SECONDS = 20
local ACTIVE_SEARCHER_REFRESH_SECONDS = 10
local ACTIVE_SEARCHER_STALE_SECONDS = 45
local CHARACTER_READY_TIMEOUT_SECONDS = 30
local CHARACTER_SETTLE_SECONDS = 2
local HIVE_CLAIM_TIMEOUT_SECONDS = 8
local HIVE_CLAIM_RETRY_SECONDS = 0.35
local HIVE_CLAIM_MAX_ATTEMPTS = 5
local HIVE_CLAIM_VERIFY_SECONDS = 1.5
local DEFAULT_HIVE_APPROACH_SPEED = 55
local MIN_HIVE_APPROACH_SPEED = 25
local MAX_HIVE_APPROACH_SPEED = 90
local HIVE_APPROACH_MAX_SECONDS = 5
local TRAVEL_MAX_VELOCITY = 145
local TRAVEL_RESPONSIVENESS = 65
local ACTIVATION_TOUCH_DISTANCE = 0.75
local ACTIVATION_DISCOVERY_SECONDS = 2.5
local ACTIVATION_APPROACH_CLEARANCE = 8
local ACTIVATION_APPROACH_DISTANCE = 2.5
local ACTIVATION_APPROACH_MAX_VELOCITY = 80
local ACTIVATION_DROP_DEPTH = 5
local ACTIVATION_DROP_MAX_VELOCITY = 35
local ACTIVATION_DROP_RETRY_SECONDS = 2
local ACTIVATION_HOLD_SECONDS = 0.15
local ACTIVATION_TIMEOUT_SECONDS = 8
local SPIKE_TRACK_SECONDS = 5
local OVERHEAD_HEIGHT = 10
local OVERHEAD_PLATFORM_SIZE = Vector3.new(20, 1, 20)
local OVERHEAD_FOLLOW_SPEED = 8
local OVERHEAD_MAX_PLATFORM_STEP = 4
local OVERHEAD_MAX_CORRECTION_DISTANCE = 5
local OVERHEAD_SETTLED_DISTANCE = 1.5
local OVERHEAD_SURFACE_SCAN_HEIGHT = 256
local OVERHEAD_SURFACE_SCAN_DEPTH = 512
local OVERHEAD_GEOMETRY_CLEARANCE = 2
local OVERHEAD_FALLBACK_MAX_VELOCITY = 65
local OVERHEAD_PLATFORM_RETRY_SECONDS = 1
local EMERGENCY_REJOIN_RETRY_SECONDS = 2

if game.PlaceId ~= BSS_PLACE_ID then
    return
end

local playerDeadline = os.clock() + 30
while not Players.LocalPlayer and os.clock() < playerDeadline do
    task.wait(0.1)
end
local PLAYER = Players.LocalPlayer
if not PLAYER then
    warn("[Vichop/Killer] LocalPlayer is unavailable")
    return
end
if not game:IsLoaded() then
    game.Loaded:Wait()
end
local characterDeadline = os.clock() + CHARACTER_READY_TIMEOUT_SECONDS
local character = PLAYER.Character
while not character and os.clock() < characterDeadline do
    task.wait(0.1)
    character = PLAYER.Character
end
while character and os.clock() < characterDeadline
    and (not character:FindFirstChildOfClass("Humanoid") or not character:FindFirstChild("HumanoidRootPart")) do
    task.wait(0.1)
end
if not character or not character:FindFirstChildOfClass("Humanoid")
    or not character:FindFirstChild("HumanoidRootPart") then
    warn("[Vichop/Killer] Character did not become ready")
    return
end
task.wait(CHARACTER_SETTLE_SECONDS)
local RESUME_FILE = "vichop_killer_resume_" .. tostring(PLAYER.UserId) .. ".json"

local env = type(getgenv) == "function" and getgenv() or _G
local HIDE_KILLER_USER = env.VICHOP_HIDE_KILLER_USER ~= false
local function readJsonFile(path)
    if type(isfile) ~= "function" or type(readfile) ~= "function" or not isfile(path) then
        return nil
    end
    local readOk, raw = pcall(readfile, path)
    if not readOk or type(raw) ~= "string" then
        return nil
    end
    local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
    return decodeOk and type(decoded) == "table" and decoded or nil
end

local function getJoinTeleportData()
    local ok, joinData = pcall(PLAYER.GetJoinData, PLAYER)
    if ok and type(joinData) == "table" and type(joinData.TeleportData) == "table"
        and joinData.TeleportData.vichopRole == "killer" then
        return joinData.TeleportData
    end
    local saved = readJsonFile(RESUME_FILE)
    if type(saved) == "table" and saved.vichopRole == "killer"
        and os.time() - tonumber(saved.savedAt or 0) <= 120 then
        return saved
    end
    return {}
end

local function getRecentStatsSessionId()
    local saved = readJsonFile(STATS_FILE)
    local updatedAt = type(saved) == "table" and tonumber(saved.updatedAt or 0) or 0
    if type(saved) == "table" and type(saved.sessionId) == "string" and saved.sessionId ~= ""
        and os.time() - updatedAt <= SESSION_RESUME_MAX_AGE_SECONDS then
        return saved.sessionId
    end
    return nil
end

local joinTeleportData = getJoinTeleportData()
local previousRuntime = env.__VICHOP_KILLER_RUNTIME
if type(previousRuntime) == "table" and previousRuntime.active and previousRuntime.jobId == game.JobId then
    print("[Vichop/Killer] Already running in this server")
    return
end
if type(previousRuntime) == "table" and type(previousRuntime.stopMovement) == "function" then
    pcall(previousRuntime.stopMovement, "runtime_replaced")
end
if type(previousRuntime) == "table" and type(previousRuntime.destroyHud) == "function" then
    pcall(previousRuntime.destroyHud)
end

local sessionId = joinTeleportData.vichopRole == "killer" and joinTeleportData.vichopSessionId
    or env.__VICHOP_KILLER_SESSION_ID
    or getRecentStatsSessionId()
if HIDE_KILLER_USER and type(sessionId) == "string" and string.match(sessionId, "^killer%-%d+%-") then
    sessionId = nil
end
if type(sessionId) ~= "string" or sessionId == "" then
    sessionId = "killer-" .. HttpService:GenerateGUID(false)
end
env.__VICHOP_KILLER_SESSION_ID = sessionId

local runtime = {
    active = true,
    jobId = game.JobId,
    state = "STARTING",
    detail = "Loading queue",
    lastResult = "None",
    currentClaimKey = nil,
    currentJob = nil,
    currentJoinedAt = nil,
    lastClaimHeartbeat = 0,
    teleportStarted = false,
    teleportError = nil,
    failedJobs = {},
    webhookInFlight = 0,
    cleanupRunning = false,
    redirectCount = math.max(0, tonumber(joinTeleportData.vichopRedirectCount) or 0),
    stingerSource = "Unavailable",
    activeSearcherCount = nil,
    activeSearcherCountAt = 0,
    activeSearcherRefreshRunning = false,
    hiveClaimed = false,
    hiveName = nil,
    emergencyRejoinActive = false,
    tweenSpeedSavePending = false,
    hiveTweenSpeed = math.clamp(
        tonumber(env.VICHOP_HIVE_TWEEN_SPEED) or DEFAULT_HIVE_APPROACH_SPEED,
        MIN_HIVE_APPROACH_SPEED,
        MAX_HIVE_APPROACH_SPEED
    ),
}
env.__VICHOP_KILLER_RUNTIME = runtime

local KILLER_NAME = HIDE_KILLER_USER and "Hidden" or PLAYER.Name
local DISCORD_WEBHOOK_URL = type(env.VICHOP_WEBHOOK_URL) == "string" and env.VICHOP_WEBHOOK_URL or ""
local WEBHOOK_USERNAME = "Vichop Tracker"
local WEBHOOK_AVATAR_URL = ""
local HUD_BACKGROUND_URL = "https://raw.githubusercontent.com/glitchreal/jjj/main/assets/honey_workspace.jpg"
local HUD_BACKGROUND_FILE = "vichop_honey_workspace.jpg"
local httpRequest = request or http_request or (syn and syn.request)
if type(httpRequest) ~= "function" then
    warn("[Vichop/Killer] Disabled: executor HTTP requests are unavailable")
    runtime.active = false
    return
end
local function now()
    return os.time()
end

local function shortJobId(jobId)
    local value = tostring(jobId or "")
    return #value > 12 and (value:sub(1, 12) .. "...") or value
end

local function copyTable(source)
    local result = {}
    for key, value in pairs(type(source) == "table" and source or {}) do
        result[key] = value
    end
    return result
end

local function formatNumber(value)
    local text = tostring(math.floor(tonumber(value) or 0))
    return text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function formatRate(value)
    return formatNumber(math.floor((tonumber(value) or 0) + 0.5)) .. "/hr"
end

local function defaultStats()
    return {
        totalKills = 0,
        totalStingers = 0,
        totalJoins = 0,
        sessionKills = 0,
        sessionStingers = 0,
        sessionJoins = 0,
        sessionId = sessionId,
        startedAt = now(),
        updatedAt = now(),
        lastCountedJobId = "",
        lastKillEventId = "",
        hiveTweenSpeed = DEFAULT_HIVE_APPROACH_SPEED,
    }
end

local function backupCorruptStats(raw)
    if type(writefile) ~= "function" or type(raw) ~= "string" or raw == "" then
        return
    end
    local backupName = STATS_FILE .. ".corrupt-" .. tostring(now()) .. ".json"
    local ok = pcall(writefile, backupName, raw)
    if ok then
        warn("[Vichop/Killer] Preserved corrupt stats as", backupName)
    end
end

local function loadStats()
    local stats = defaultStats()
    if type(isfile) ~= "function" or type(readfile) ~= "function" or not isfile(STATS_FILE) then
        return stats
    end

    local readOk, raw = pcall(readfile, STATS_FILE)
    if not readOk or type(raw) ~= "string" then
        warn("[Vichop/Killer] Could not read stats; starting with defaults")
        return stats
    end
    local decodeOk, saved = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decodeOk or type(saved) ~= "table" then
        backupCorruptStats(raw)
        return stats
    end

    for _, key in ipairs({ "totalKills", "totalStingers", "totalJoins" }) do
        stats[key] = math.max(0, tonumber(saved[key]) or 0)
    end
    stats.lastKillEventId = type(saved.lastKillEventId) == "string" and saved.lastKillEventId or ""
    stats.lastCountedJobId = type(saved.lastCountedJobId) == "string" and saved.lastCountedJobId or ""
    stats.hiveTweenSpeed = math.clamp(
        tonumber(saved.hiveTweenSpeed) or stats.hiveTweenSpeed,
        MIN_HIVE_APPROACH_SPEED,
        MAX_HIVE_APPROACH_SPEED
    )

    local migrateHiddenSession = HIDE_KILLER_USER and type(saved.sessionId) == "string"
        and string.match(saved.sessionId, "^killer%-%d+%-") ~= nil
        and now() - tonumber(saved.updatedAt or 0) <= SESSION_RESUME_MAX_AGE_SECONDS
    if saved.sessionId == sessionId or migrateHiddenSession then
        for _, key in ipairs({ "sessionKills", "sessionStingers", "sessionJoins" }) do
            stats[key] = math.max(0, tonumber(saved[key]) or 0)
        end
        stats.startedAt = tonumber(saved.startedAt) or now()
    end
    return stats
end

local stats = loadStats()
runtime.hiveTweenSpeed = math.clamp(
    tonumber(env.VICHOP_HIVE_TWEEN_SPEED) or stats.hiveTweenSpeed or DEFAULT_HIVE_APPROACH_SPEED,
    MIN_HIVE_APPROACH_SPEED,
    MAX_HIVE_APPROACH_SPEED
)
env.VICHOP_HIVE_TWEEN_SPEED = runtime.hiveTweenSpeed

local function saveStats()
    stats.updatedAt = now()
    if type(writefile) ~= "function" then
        return false
    end
    local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, stats)
    if not encodeOk then
        warn("[Vichop/Killer] Could not encode stats")
        return false
    end

    local tempFile = STATS_FILE .. ".tmp"
    local tempOk, tempError = pcall(writefile, tempFile, encoded)
    if not tempOk then
        warn("[Vichop/Killer] Could not write temporary stats:", tostring(tempError))
        return false
    end
    local finalOk, finalError = pcall(writefile, STATS_FILE, encoded)
    if type(delfile) == "function" then
        pcall(delfile, tempFile)
    end
    if not finalOk then
        warn("[Vichop/Killer] Could not save stats:", tostring(finalError))
    end
    return finalOk
end

local function saveHiveTweenSpeed(immediate)
    stats.hiveTweenSpeed = runtime.hiveTweenSpeed
    if immediate then
        runtime.tweenSpeedSavePending = false
        return saveStats()
    end
    if runtime.tweenSpeedSavePending then
        return true
    end
    runtime.tweenSpeedSavePending = true
    task.delay(0.35, function()
        if env.__VICHOP_KILLER_RUNTIME == runtime then
            stats.hiveTweenSpeed = runtime.hiveTweenSpeed
            saveStats()
        end
        runtime.tweenSpeedSavePending = false
    end)
    return true
end

if stats.lastCountedJobId ~= game.JobId then
    stats.totalJoins = stats.totalJoins + 1
    stats.sessionJoins = stats.sessionJoins + 1
    stats.lastCountedJobId = game.JobId
    saveStats()
end

local function notify(title, text)
    print("[Vichop/Killer] " .. title .. " - " .. text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = 5 })
    end)
end

local function responseStatus(response)
    return tonumber(response and (response.StatusCode or response.status_code or response.Status)) or 0
end

local function responseHeader(response, wantedName)
    local headers = response and (response.Headers or response.headers) or {}
    for name, value in pairs(type(headers) == "table" and headers or {}) do
        if string.lower(tostring(name)) == string.lower(wantedName) then
            return tostring(value)
        end
    end
    return nil
end

local function rawRequest(options)
    options.Timeout = options.Timeout or HTTP_TIMEOUT_SECONDS
    local ok, response = pcall(httpRequest, options)
    if not ok or type(response) ~= "table" then
        warn("[Vichop/Killer] HTTP request failed:", tostring(response))
        return nil, 0
    end
    return response, responseStatus(response)
end

local function decodeBody(response)
    local body = response and (response.Body or response.body) or ""
    if body == "" or body == "null" then
        return nil, true
    end
    local ok, decoded = pcall(HttpService.JSONDecode, HttpService, body)
    if not ok then
        warn("[Vichop/Killer] Could not decode an HTTP response")
        return nil, false
    end
    return decoded, true
end

local function firebaseRequest(method, path, body, extraHeaders)
    local headers = { ["Content-Type"] = "application/json" }
    for name, value in pairs(extraHeaders or {}) do
        headers[name] = value
    end
    local options = {
        Url = DATABASE_URL .. path,
        Method = method,
        Headers = headers,
    }
    if body ~= nil then
        local encodedOk, encoded = pcall(HttpService.JSONEncode, HttpService, body)
        if not encodedOk then
            warn("[Vichop/Killer] Could not encode Firebase payload for", path)
            return nil, 0, false
        end
        options.Body = encoded
    end
    local response, status = rawRequest(options)
    if status < 200 or status >= 300 then
        if status ~= 412 then
            warn("[Vichop/Killer] Firebase request failed:", method, path, status)
        end
        return response, status, false
    end
    return response, status, true
end

local function firebaseGet(path)
    local response, _, ok = firebaseRequest("GET", path)
    if not ok then
        return nil, false
    end
    local decoded, decodedOk = decodeBody(response)
    return decoded, decodedOk
end

local function firebaseGetWithEtag(path)
    local response, _, ok = firebaseRequest("GET", path, nil, { ["X-Firebase-ETag"] = "true" })
    if not ok then
        return nil, nil, false
    end
    local value, decodedOk = decodeBody(response)
    local etag = responseHeader(response, "etag")
    if not decodedOk or not etag then
        warn("[Vichop/Killer] Atomic Firebase operation unavailable for", path)
        return nil, nil, false
    end
    return value, etag, true
end

local function atomicMutate(path, mutator, attempts)
    for _ = 1, attempts or 4 do
        local current, etag, readOk = firebaseGetWithEtag(path)
        if not readOk then
            return false, "read_failed", current
        end
        local replacement, reason = mutator(current)
        if replacement == nil then
            return false, reason or "rejected", current
        end
        local _, status, writeOk = firebaseRequest("PUT", path, replacement, { ["if-match"] = etag })
        if writeOk then
            return true, reason or "updated", replacement
        end
        if status ~= 412 then
            return false, "write_failed", current
        end
        task.wait(0.05)
    end
    return false, "contended", nil
end

local function atomicDeleteIf(path, predicate)
    for _ = 1, 3 do
        local current, etag, readOk = firebaseGetWithEtag(path)
        if not readOk then
            return false
        end
        if current == nil then
            return true
        end
        if not predicate(current) then
            return false
        end
        local _, status, writeOk = firebaseRequest("DELETE", path, nil, { ["if-match"] = etag })
        if writeOk then
            return true
        end
        if status ~= 412 then
            return false
        end
    end
    return false
end

local function jobPath(key)
    return "/jobs/" .. tostring(key) .. ".json"
end

local function getActiveSearcherCount()
    local reservations, readOk = firebaseGet("/activeServers.json")
    if not readOk or type(reservations) ~= "table" then
        return nil
    end

    local timestamp = now()
    local activeIds = {}
    for _, reservation in pairs(reservations) do
        if type(reservation) == "table"
            and tonumber(reservation.placeId) == game.PlaceId
            and type(reservation.searcherId) == "string"
            and tonumber(reservation.heartbeatAt or 0) >= timestamp - ACTIVE_SEARCHER_TTL_SECONDS then
            activeIds[reservation.searcherId] = true
        end
    end

    local count = 0
    for _ in pairs(activeIds) do
        count = count + 1
    end
    return count
end

local function refreshActiveSearcherCount()
    if runtime.activeSearcherRefreshRunning then
        return
    end
    runtime.activeSearcherRefreshRunning = true
    task.spawn(function()
        local count = getActiveSearcherCount()
        if count ~= nil then
            runtime.activeSearcherCount = count
            runtime.activeSearcherCountAt = now()
        end
        runtime.activeSearcherRefreshRunning = false
    end)
end

local function activeSearcherDisplay()
    if runtime.activeSearcherCount == nil
        or now() - runtime.activeSearcherCountAt > ACTIVE_SEARCHER_STALE_SECONDS then
        return "Unknown"
    end
    return formatNumber(runtime.activeSearcherCount)
end

local function sessionStingersPerHour()
    local uptime = math.max(1, now() - stats.startedAt)
    return stats.sessionStingers * 3600 / uptime
end

local clientStatCache = nil
local clientStatCacheChecked = false
local function getClientStatCache()
    if clientStatCacheChecked then
        return clientStatCache
    end
    clientStatCacheChecked = true
    local module = ReplicatedStorage:FindFirstChild("ClientStatCache")
    if module and module:IsA("ModuleScript") then
        local ok, cache = pcall(require, module)
        if ok and type(cache) == "table" and type(cache.Get) == "function" then
            clientStatCache = cache
        end
    end
    return clientStatCache
end

local function getStingers()
    local cache = getClientStatCache()
    if cache then
        local ok, playerStats = pcall(cache.Get, cache)
        local eggs = ok and type(playerStats) == "table" and playerStats.Eggs or nil
        local value = type(eggs) == "table" and tonumber(eggs.Stinger) or nil
        if value then
            runtime.stingerSource = "ClientStatCache.Eggs.Stinger"
            return math.max(0, math.floor(value))
        end
    end

    local coreStats = PLAYER:FindFirstChild("CoreStats")
    local stingers = coreStats and coreStats:FindFirstChild("Stingers")
    if stingers and (stingers:IsA("IntValue") or stingers:IsA("NumberValue")) then
        runtime.stingerSource = "CoreStats.Stingers"
        return math.max(0, math.floor(tonumber(stingers.Value) or 0))
    end
    runtime.stingerSource = "Unavailable"
    return nil
end

local function getVicious()
    local monsters = workspace:FindFirstChild("Monsters")
    if not monsters then
        return nil, nil, nil
    end
    for _, monster in ipairs(monsters:GetChildren()) do
        if monster:IsA("Model") then
            local monsterType = monster:FindFirstChild("MonsterType")
            local typeName = monsterType and tostring(monsterType.Value) or monster.Name
            local humanoid = monster:FindFirstChildOfClass("Humanoid")
            if string.find(string.lower(typeName), "vicious bee", 1, true)
                and humanoid and humanoid.Health > 0 then
                local levelObject = monster:FindFirstChild("Level", true)
                local level = levelObject and tonumber(levelObject.Value) or tonumber(monster:GetAttribute("Level"))
                if not level then
                    level = tonumber(string.match(monster.Name, "[Ll]evel%s*(%d+)"))
                        or tonumber(string.match(monster.Name, "[Ll]vl%s*(%d+)"))
                end
                return monster, humanoid, level
            end
        end
    end
    return nil, nil, nil
end

local function getCharacterParts()
    local currentCharacter = PLAYER.Character
    local humanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
    local root = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")
    if not currentCharacter or not humanoid or not root or humanoid.Health <= 0 then
        return nil, nil, nil
    end
    return currentCharacter, humanoid, root
end

local function getPlatformData(platform)
    if not platform or not platform:IsA("Model") then
        return nil, nil, nil
    end
    local playerRef = platform:FindFirstChild("PlayerRef")
    local hiveRef = platform:FindFirstChild("Hive")
    local hive = hiveRef and hiveRef.Value
    local platformPart = platform:FindFirstChild("Platform")
    if not playerRef or not hive or not hive:IsA("Model") or not platformPart or not platformPart:IsA("BasePart") then
        return nil, nil, nil
    end
    return playerRef, hive, platformPart
end

local function findOwnedHivePlatform()
    local platforms = workspace:FindFirstChild("HivePlatforms")
    if not platforms then
        return nil, nil
    end
    for _, platform in ipairs(platforms:GetChildren()) do
        local playerRef, hive = getPlatformData(platform)
        local owner = hive and hive:FindFirstChild("Owner")
        if playerRef and (playerRef.Value == PLAYER or (owner and owner.Value == PLAYER)) then
            return platform, hive
        end
    end
    return nil, nil
end

local function findNearestEmptyHivePlatform(root)
    local platforms = workspace:FindFirstChild("HivePlatforms")
    if not platforms then
        return nil, nil, nil
    end
    local bestPlatform, bestHive, bestPart, bestDistance
    for _, platform in ipairs(platforms:GetChildren()) do
        local playerRef, hive, platformPart = getPlatformData(platform)
        local owner = hive and hive:FindFirstChild("Owner")
        local phase = hive and hive:FindFirstChild("Phase")
        local unoccupied = playerRef and playerRef.Value == nil and (not owner or owner.Value == nil)
            and (not phase or phase.Value == "Idle")
        if unoccupied then
            local distance = (root.Position - platformPart.Position).Magnitude
            if not bestDistance or distance < bestDistance then
                bestPlatform, bestHive, bestPart, bestDistance = platform, hive, platformPart, distance
            end
        end
    end
    return bestPlatform, bestHive, bestPart
end

local function tweenToHivePlatform(platform, platformPart)
    local currentCharacter, humanoid, root = getCharacterParts()
    if not currentCharacter or not platform or not platformPart then
        return false
    end
    local originalCollisions = {}
    local originalAnchored = root.Anchored
    local originalAutoRotate = humanoid.AutoRotate
    for _, descendant in ipairs(currentCharacter:GetDescendants()) do
        if descendant:IsA("BasePart") then
            originalCollisions[descendant] = descendant.CanCollide
            descendant.CanCollide = false
        end
    end
    humanoid.AutoRotate = false
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.Anchored = true

    local function restoreCharacter()
        if root.Parent then
            root.Anchored = originalAnchored
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
        if humanoid.Parent then
            humanoid.AutoRotate = originalAutoRotate
        end
        for part, canCollide in pairs(originalCollisions) do
            if part.Parent then
                part.CanCollide = canCollide
            end
        end
    end

    local target = platformPart.CFrame * CFrame.new(0, 3.25, 0)
    local duration = math.clamp(
        (root.Position - target.Position).Magnitude / runtime.hiveTweenSpeed,
        0.2,
        HIVE_APPROACH_MAX_SECONDS
    )
    local tweenOk, tween = pcall(
        TweenService.Create,
        TweenService,
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        { CFrame = target }
    )
    if not tweenOk or not tween then
        restoreCharacter()
        return false
    end
    local finished = false
    local completedConnection = tween.Completed:Connect(function(playbackState)
        finished = playbackState == Enum.PlaybackState.Completed
    end)
    local playOk = pcall(tween.Play, tween)
    if not playOk then
        completedConnection:Disconnect()
        restoreCharacter()
        return false
    end
    local deadline = os.clock() + duration + 0.75
    while runtime.active and not runtime.teleportStarted and not finished and os.clock() < deadline do
        task.wait()
    end
    if not finished then
        tween:Cancel()
    end
    completedConnection:Disconnect()
    restoreCharacter()
    return finished and (root.Position - target.Position).Magnitude <= 7
end

local function claimAvailableHive()
    local ownedPlatform, ownedHive = findOwnedHivePlatform()
    if ownedPlatform then
        runtime.hiveClaimed = true
        runtime.hiveName = ownedHive.Name
        return true
    end

    local claimRemote
    local remoteDeadline = os.clock() + HIVE_CLAIM_TIMEOUT_SECONDS
    while runtime.active and not runtime.teleportStarted and os.clock() < remoteDeadline do
        local events = ReplicatedStorage:FindFirstChild("Events")
        local candidate = events and events:FindFirstChild("ClaimHive")
        if candidate and candidate:IsA("RemoteEvent") then
            claimRemote = candidate
            break
        end
        task.wait(0.15)
    end
    if not claimRemote then
        warn("[Vichop/Killer] ClaimHive remote is unavailable")
        return false
    end

    local deadline = os.clock() + HIVE_CLAIM_TIMEOUT_SECONDS + HIVE_CLAIM_VERIFY_SECONDS
    local attempt = 0
    while runtime.active and not runtime.teleportStarted and os.clock() < deadline
        and attempt < HIVE_CLAIM_MAX_ATTEMPTS do
        local _, _, root = getCharacterParts()
        if not root then
            task.wait(HIVE_CLAIM_RETRY_SECONDS)
            continue
        end
        local platform, hive, platformPart = findNearestEmptyHivePlatform(root)
        if not platform then
            warn("[Vichop/Killer] No unoccupied hive snapshot; rescanning")
            task.wait(HIVE_CLAIM_RETRY_SECONDS)
            continue
        end
        attempt = attempt + 1

        if not tweenToHivePlatform(platform, platformPart) then
            warn("[Vichop/Killer] Could not reach", hive.Name, "on claim attempt", attempt)
            task.wait(HIVE_CLAIM_RETRY_SECONDS)
            continue
        end

        local playerRef, currentHive = getPlatformData(platform)
        local owner = currentHive and currentHive:FindFirstChild("Owner")
        if playerRef and playerRef.Value == nil and (not owner or owner.Value == nil) then
            local hiveId = currentHive:FindFirstChild("HiveID")
            if hiveId then
                local fired, fireError = pcall(claimRemote.FireServer, claimRemote, hiveId.Value)
                if not fired then
                    warn("[Vichop/Killer] ClaimHive request failed:", tostring(fireError))
                end
            else
                warn("[Vichop/Killer] HiveID was unavailable; rescanning")
            end
        else
            warn("[Vichop/Killer] Hive became occupied before claim; rescanning")
        end

        local verifyDeadline = math.min(deadline, os.clock() + HIVE_CLAIM_VERIFY_SECONDS)
        while runtime.active and os.clock() < verifyDeadline do
            local claimedPlatform, claimedHive = findOwnedHivePlatform()
            if claimedPlatform then
                runtime.hiveClaimed = true
                runtime.hiveName = claimedHive.Name
                print("[Vichop/Killer] Claimed", claimedHive.Name)
                return true
            end
            task.wait(0.1)
        end
        print("[Vichop/Killer] Hive claim not confirmed on attempt", attempt, "; retrying")
        task.wait(HIVE_CLAIM_RETRY_SECONDS)
    end
    warn("[Vichop/Killer] Hive claim was not confirmed; continuing to the Vicious target")
    return false
end

local movement = {
    active = false,
    mode = "idle",
    target = nil,
    attachment = nil,
    alignPosition = nil,
    alignOrientation = nil,
    updateConnection = nil,
    hazardConnection = nil,
    noclipConnection = nil,
    character = nil,
    humanoid = nil,
    overheadPlatform = nil,
    activationTarget = nil,
    activationStage = "idle",
    activationStartedAt = 0,
    activationDropStartedAt = 0,
    activationTouchedAt = 0,
    activationTouchConnection = nil,
    hoverReferenceKind = "vicious",
    lastPlatformRetryAt = 0,
    originalAutoRotate = nil,
    originalCollisions = {},
    hazards = setmetatable({}, { __mode = "k" }),
}

local function getMonsterRoot(monster)
    if not monster or not monster.Parent then
        return nil
    end
    return monster:FindFirstChild("HumanoidRootPart") or monster.PrimaryPart
        or monster:FindFirstChild("Torso") or monster:FindFirstChild("Head")
end

local function getViciousActivationSpike()
    local particles = workspace:FindFirstChild("Particles")
    local activation = particles and particles:FindFirstChild("Vicious")
    return activation and activation:IsA("BasePart") and activation or nil
end

local function distanceToPartBounds(position, part)
    local localPosition = part.CFrame:PointToObjectSpace(position)
    local halfSize = part.Size * 0.5
    local closest = Vector3.new(
        math.clamp(localPosition.X, -halfSize.X, halfSize.X),
        math.clamp(localPosition.Y, -halfSize.Y, halfSize.Y),
        math.clamp(localPosition.Z, -halfSize.Z, halfSize.Z)
    )
    return (position - part.CFrame:PointToWorldSpace(closest)).Magnitude
end

local function activationSweepPositions(activation)
    local halfHeight = activation.Size.Y * 0.5
    local position = activation.Position
    return Vector3.new(
        position.X,
        position.Y + halfHeight + ACTIVATION_APPROACH_CLEARANCE,
        position.Z
    ), Vector3.new(
        position.X,
        position.Y - halfHeight - ACTIVATION_DROP_DEPTH,
        position.Z
    )
end

local function createOverheadPlatform(targetPosition)
    local ok, platform = pcall(Instance.new, "Part")
    if not ok or not platform then
        return nil
    end
    platform.Name = "VichopOverheadPlatform"
    platform.Size = OVERHEAD_PLATFORM_SIZE
    platform.Anchored = true
    platform.CanCollide = true
    platform.CanTouch = false
    platform.CanQuery = false
    platform.Transparency = 1
    platform.CastShadow = false
    platform.CFrame = CFrame.new(targetPosition)
    local parented = pcall(function()
        platform.Parent = workspace
    end)
    if not parented then
        platform:Destroy()
        return nil
    end
    return platform
end

local function disableTravelNoclip()
    if movement.noclipConnection then
        movement.noclipConnection:Disconnect()
        movement.noclipConnection = nil
    end
    for part, canCollide in pairs(movement.originalCollisions) do
        if part.Parent then
            part.CanCollide = canCollide
        end
    end
    table.clear(movement.originalCollisions)
end

local function enableTravelNoclip(currentCharacter)
    disableTravelNoclip()
    local function apply()
        if not movement.active or (movement.mode ~= "activate" and movement.mode ~= "overhead"
            and movement.mode ~= "hover")
            or PLAYER.Character ~= currentCharacter then
            return
        end
        for _, descendant in ipairs(currentCharacter:GetDescendants()) do
            if descendant:IsA("BasePart") then
                if movement.originalCollisions[descendant] == nil then
                    movement.originalCollisions[descendant] = descendant.CanCollide
                end
                descendant.CanCollide = false
            end
        end
    end
    apply()
    movement.noclipConnection = RunService.Stepped:Connect(apply)
end

local function isSpikeName(instance)
    local cursor = instance
    for _ = 1, 3 do
        if not cursor then
            break
        end
        local name = string.lower(cursor.Name)
        if string.find(name, "spike", 1, true) or string.find(name, "stinger", 1, true)
            or string.find(name, "thorn", 1, true) then
            return true
        end
        cursor = cursor.Parent
    end
    return false
end

local function observeSpikeCandidate(instance)
    if not movement.active or not instance:IsA("BasePart") then
        return
    end
    local currentCharacter, _, root = getCharacterParts()
    if not currentCharacter or not root or instance:IsDescendantOf(currentCharacter)
        or (movement.target and instance:IsDescendantOf(movement.target)) then
        return
    end
    local particles = workspace:FindFirstChild("Particles")
    local inParticles = particles and instance:IsDescendantOf(particles)
    local viciousVisual = particles and particles:FindFirstChild("Vicious")
    if viciousVisual and (instance == viciousVisual or instance:IsDescendantOf(viciousVisual)) then
        return
    end
    local lowerName = string.lower(instance.Name)
    local exactAttackSignal = instance.Parent == particles
        and (lowerName == "thorn" or lowerName == "warningdisk")
    local nameSignal = isSpikeName(instance)
    local distance = (instance.Position - root.Position).Magnitude
    local size = instance.Size
    local pointedOrWarningShape = size.Y >= math.max(size.X, size.Z) * 1.25
        or (size.Y <= 0.75 and math.max(size.X, size.Z) >= 1.5)
        or instance:IsA("MeshPart") or instance:FindFirstChildOfClass("SpecialMesh") ~= nil
    local hasAlignMover = instance:FindFirstChildWhichIsA("AlignPosition", true) ~= nil
    local anonymousParticleSignal = inParticles and distance <= 20 and not instance.CanCollide
        and pointedOrWarningShape and (instance.Anchored or not hasAlignMover)
    if exactAttackSignal or nameSignal or anonymousParticleSignal then
        local observedPosition = instance.Position
        if lowerName == "thorn" then
            observedPosition = Vector3.new(
                instance.Position.X,
                instance.Position.Y - instance.Size.Y * 0.5,
                instance.Position.Z
            )
        end
        movement.hazards[instance] = {
            observedAt = os.clock(),
            position = observedPosition,
            priority = lowerName == "warningdisk" and 3 or (lowerName == "thorn" and 2 or 1),
        }
    end
end

local function getActiveSpikePosition()
    local bestData
    local timestamp = os.clock()
    for instance, data in pairs(movement.hazards) do
        if not instance.Parent or timestamp - data.observedAt > SPIKE_TRACK_SECONDS then
            movement.hazards[instance] = nil
        else
            local lowerName = string.lower(instance.Name)
            if lowerName == "thorn" then
                data.position = Vector3.new(
                    instance.Position.X,
                    instance.Position.Y - instance.Size.Y * 0.5,
                    instance.Position.Z
                )
            else
                data.position = instance.Position
            end
        end
        if instance.Parent and timestamp - data.observedAt <= SPIKE_TRACK_SECONDS
            and (not bestData or data.priority > bestData.priority
            or (data.priority == bestData.priority and data.observedAt > bestData.observedAt)) then
            bestData = data
        end
    end
    return bestData and bestData.position or nil
end

local function getHoverReferencePosition(targetPosition)
    local spikePosition = getActiveSpikePosition()
    if spikePosition then
        movement.hoverReferenceKind = "spike"
        return spikePosition
    end
    local activation = getViciousActivationSpike()
    if activation and activation ~= movement.activationTarget then
        movement.hoverReferenceKind = "spawn"
        return activation.Position
    end
    movement.hoverReferenceKind = "vicious"
    return targetPosition
end

local function movementFilter(currentCharacter, monster, platform)
    local filter = { currentCharacter, monster }
    local particles = workspace:FindFirstChild("Particles")
    if particles then
        table.insert(filter, particles)
    end
    if platform then
        table.insert(filter, platform)
    end
    return filter
end

local function safeOverheadPlatformPosition(referencePosition, currentCharacter, monster, platform)
    local desiredY = referencePosition.Y + OVERHEAD_HEIGHT
    local filter = movementFilter(currentCharacter, monster, platform)

    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = filter
    pcall(function()
        rayParams.RespectCanCollide = true
    end)
    local rayOrigin = Vector3.new(
        referencePosition.X,
        referencePosition.Y + OVERHEAD_SURFACE_SCAN_HEIGHT,
        referencePosition.Z
    )
    local surface = workspace:Raycast(
        rayOrigin,
        Vector3.new(0, -OVERHEAD_SURFACE_SCAN_DEPTH, 0),
        rayParams
    )
    if surface then
        desiredY = math.max(desiredY, surface.Position.Y + OVERHEAD_HEIGHT)
    end

    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    overlapParams.FilterDescendantsInstances = filter
    overlapParams.MaxParts = 50
    pcall(function()
        overlapParams.RespectCanCollide = true
    end)
    local checkCenter = Vector3.new(referencePosition.X, desiredY + 3, referencePosition.Z)
    local checkSize = Vector3.new(
        OVERHEAD_PLATFORM_SIZE.X - 2,
        8,
        OVERHEAD_PLATFORM_SIZE.Z - 2
    )
    local ok, parts = pcall(workspace.GetPartBoundsInBox, workspace, CFrame.new(checkCenter), checkSize, overlapParams)
    if ok then
        for _, part in ipairs(parts) do
            if part.CanCollide then
                local highestPoint = part.Position.Y + part.Size.Y * 0.5
                if highestPoint + OVERHEAD_GEOMETRY_CLEARANCE >= desiredY then
                    desiredY = highestPoint + OVERHEAD_HEIGHT
                end
            end
        end
    end
    return Vector3.new(referencePosition.X, desiredY, referencePosition.Z)
end

local function smoothPlatformPosition(currentPosition, desiredPosition, deltaTime)
    local alpha = 1 - math.exp(-OVERHEAD_FOLLOW_SPEED * math.max(deltaTime, 0))
    local delta = desiredPosition - currentPosition
    local step = delta * math.clamp(alpha, 0, 1)
    if step.Magnitude > OVERHEAD_MAX_PLATFORM_STEP then
        step = step.Unit * OVERHEAD_MAX_PLATFORM_STEP
    end
    return currentPosition + step
end

local function stopMovement(reason)
    movement.active = false
    movement.mode = "idle"
    movement.target = nil
    movement.activationTarget = nil
    movement.activationStage = "idle"
    movement.activationStartedAt = 0
    movement.activationDropStartedAt = 0
    movement.activationTouchedAt = 0
    movement.lastPlatformRetryAt = 0
    disableTravelNoclip()
    for _, connectionName in ipairs({ "updateConnection", "hazardConnection", "activationTouchConnection" }) do
        local connection = movement[connectionName]
        movement[connectionName] = nil
        if connection then
            connection:Disconnect()
        end
    end
    for _, instanceName in ipairs({ "overheadPlatform", "alignPosition", "alignOrientation", "attachment" }) do
        local instance = movement[instanceName]
        movement[instanceName] = nil
        if instance then
            instance:Destroy()
        end
    end
    local humanoid = movement.humanoid
    if humanoid and humanoid.Parent then
        humanoid:Move(Vector3.zero)
        if movement.originalAutoRotate ~= nil then
            humanoid.AutoRotate = movement.originalAutoRotate
        end
    end
    movement.character = nil
    movement.humanoid = nil
    movement.hoverReferenceKind = "vicious"
    movement.originalAutoRotate = nil
    table.clear(movement.hazards)
    if reason then
        runtime.movementStopReason = reason
    end
end
runtime.stopMovement = stopMovement

local function enterActivationMode(currentCharacter, humanoid, activationTarget)
    movement.mode = "activate"
    movement.activationTarget = activationTarget
    movement.activationStage = "approach"
    movement.activationStartedAt = os.clock()
    movement.activationDropStartedAt = 0
    movement.activationTouchedAt = 0
    humanoid.AutoRotate = false
    movement.alignPosition.Enabled = true
    movement.alignPosition.MaxVelocity = ACTIVATION_APPROACH_MAX_VELOCITY
    movement.alignOrientation.Enabled = true
    enableTravelNoclip(currentCharacter)
    local root = currentCharacter:FindFirstChild("HumanoidRootPart")
    if root then
        movement.activationTouchConnection = root.Touched:Connect(function(otherPart)
            if movement.mode == "activate" and movement.activationTouchedAt == 0
                and otherPart == activationTarget then
                movement.activationTouchedAt = os.clock()
                print("[Vichop/Killer] Native contact with Vicious activation spike confirmed")
            end
        end)
    end
    print("[Vichop/Killer] Approaching above Vicious activation spike")
end

local function clearActivationTracking()
    movement.activationTarget = nil
    movement.activationStage = "idle"
    movement.activationDropStartedAt = 0
    if movement.activationTouchConnection then
        movement.activationTouchConnection:Disconnect()
        movement.activationTouchConnection = nil
    end
end

local function enterOverheadMode(currentCharacter, humanoid, targetPosition, monster)
    clearActivationTracking()
    humanoid.AutoRotate = false
    humanoid:Move(Vector3.zero)
    movement.alignPosition.Enabled = true
    movement.alignPosition.MaxVelocity = OVERHEAD_FALLBACK_MAX_VELOCITY
    movement.alignPosition.Responsiveness = 24
    movement.alignOrientation.Enabled = false
    enableTravelNoclip(currentCharacter)

    local referencePosition = getHoverReferencePosition(targetPosition)
    local safePosition = safeOverheadPlatformPosition(
        referencePosition,
        currentCharacter,
        monster,
        movement.overheadPlatform
    )
    local platform = createOverheadPlatform(safePosition)
    if not platform then
        movement.mode = "hover"
        local _, _, root = getCharacterParts()
        local standingHeight = humanoid.HipHeight + (root and root.Size.Y * 0.5 or 1)
        movement.alignPosition.Position = safePosition + Vector3.new(0, standingHeight, 0)
        warn("[Vichop/Killer] Platform creation failed; using safe overhead hover fallback")
        return false
    end
    movement.mode = "overhead"
    movement.overheadPlatform = platform
    movement.lastPlatformRetryAt = 0
    print("[Vichop/Killer] Universal overhead platform active above", movement.hoverReferenceKind)
    return true
end

local function startMovement(monster)
    stopMovement()
    local currentCharacter, humanoid, root = getCharacterParts()
    local monsterRoot = getMonsterRoot(monster)
    if not currentCharacter or not monsterRoot then
        return false
    end

    movement.active = true
    movement.target = monster
    movement.character = currentCharacter
    movement.humanoid = humanoid
    movement.originalAutoRotate = humanoid.AutoRotate

    local attachment = Instance.new("Attachment")
    attachment.Name = "VichopMovementAttachment"
    attachment.Parent = root
    movement.attachment = attachment

    local alignPosition = Instance.new("AlignPosition")
    alignPosition.Name = "VichopTravelPosition"
    alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
    alignPosition.Attachment0 = attachment
    alignPosition.ApplyAtCenterOfMass = true
    alignPosition.MaxForce = 1000000
    alignPosition.MaxVelocity = TRAVEL_MAX_VELOCITY
    alignPosition.Responsiveness = TRAVEL_RESPONSIVENESS
    alignPosition.RigidityEnabled = false
    alignPosition.Enabled = false
    alignPosition.Parent = root
    movement.alignPosition = alignPosition

    local alignOrientation = Instance.new("AlignOrientation")
    alignOrientation.Name = "VichopTravelOrientation"
    alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
    alignOrientation.Attachment0 = attachment
    alignOrientation.MaxTorque = 1000000
    alignOrientation.Responsiveness = 45
    alignOrientation.RigidityEnabled = false
    alignOrientation.Enabled = false
    alignOrientation.Parent = root
    movement.alignOrientation = alignOrientation

    local activationTarget = getViciousActivationSpike()
    local activationDeadline = os.clock() + ACTIVATION_DISCOVERY_SECONDS
    while not activationTarget and runtime.active and monster.Parent
        and os.clock() < activationDeadline do
        task.wait(0.1)
        activationTarget = getViciousActivationSpike()
    end
    if activationTarget then
        enterActivationMode(currentCharacter, humanoid, activationTarget)
    else
        print("[Vichop/Killer] No activation spike present; Vicious appears to be active already")
        enterOverheadMode(currentCharacter, humanoid, monsterRoot.Position, monster)
    end
    local particles = workspace:FindFirstChild("Particles")
    if particles then
        for _, instance in ipairs(particles:GetDescendants()) do
            observeSpikeCandidate(instance)
        end
    end
    movement.hazardConnection = workspace.DescendantAdded:Connect(observeSpikeCandidate)
    movement.updateConnection = RunService.Heartbeat:Connect(function(deltaTime)
        if not movement.active or not runtime.active or runtime.teleportStarted then
            stopMovement(runtime.teleportStarted and "teleport" or "runtime_stopped")
            return
        end
        local activeCharacter, activeHumanoid, activeRoot = getCharacterParts()
        local activeMonsterRoot = getMonsterRoot(monster)
        local monsterHumanoid = monster and monster:FindFirstChildOfClass("Humanoid")
        if not activeCharacter or activeCharacter ~= movement.character or not activeMonsterRoot
            or not monsterHumanoid or monsterHumanoid.Health <= 0 then
            stopMovement("target_unavailable")
            return
        end

        local targetPosition = activeMonsterRoot.Position
        if movement.mode == "activate" then
            local activation = movement.activationTarget
            if not activation or not activation.Parent then
                enterOverheadMode(activeCharacter, activeHumanoid, targetPosition, monster)
                return
            end

            local timestamp = os.clock()
            local abovePosition, belowPosition = activationSweepPositions(activation)
            if movement.activationTouchedAt > 0 then
                if timestamp - movement.activationTouchedAt >= ACTIVATION_HOLD_SECONDS then
                    print("[Vichop/Killer] Vicious activation spike touched; moving to combat")
                    enterOverheadMode(activeCharacter, activeHumanoid, targetPosition, monster)
                end
                return
            end

            if timestamp - movement.activationStartedAt >= ACTIVATION_TIMEOUT_SECONDS then
                warn("[Vichop/Killer] Activation sweep timed out; applying touch fallback")
                if type(firetouchinterest) == "function" then
                    pcall(firetouchinterest, activeRoot, activation, 0)
                    pcall(firetouchinterest, activeRoot, activation, 1)
                end
                enterOverheadMode(activeCharacter, activeHumanoid, targetPosition, monster)
                return
            end

            if movement.activationStage == "approach" then
                movement.alignPosition.Position = abovePosition
                if (activeRoot.Position - abovePosition).Magnitude <= ACTIVATION_APPROACH_DISTANCE then
                    movement.activationStage = "drop"
                    movement.activationDropStartedAt = timestamp
                    movement.alignPosition.MaxVelocity = ACTIVATION_DROP_MAX_VELOCITY
                    activeRoot.AssemblyLinearVelocity = Vector3.zero
                    print("[Vichop/Killer] Above activation spike; dropping through it")
                end
            else
                movement.alignPosition.Position = belowPosition
                local touchingBounds = distanceToPartBounds(activeRoot.Position, activation)
                    <= ACTIVATION_TOUCH_DISTANCE
                if touchingBounds then
                    movement.activationTouchedAt = timestamp
                    if type(firetouchinterest) == "function" then
                        pcall(firetouchinterest, activeRoot, activation, 0)
                        pcall(firetouchinterest, activeRoot, activation, 1)
                    end
                elseif timestamp - movement.activationDropStartedAt >= ACTIVATION_DROP_RETRY_SECONDS
                    or activeRoot.Position.Y <= belowPosition.Y + 1 then
                    movement.activationStage = "approach"
                    movement.activationDropStartedAt = 0
                    movement.alignPosition.MaxVelocity = ACTIVATION_APPROACH_MAX_VELOCITY
                    print("[Vichop/Killer] Spike contact missed; retrying vertical drop")
                end
            end
            local flatActivationPosition = Vector3.new(
                activation.Position.X,
                activeRoot.Position.Y,
                activation.Position.Z
            )
            if (activeRoot.Position - flatActivationPosition).Magnitude > 0.1 then
                movement.alignOrientation.CFrame = CFrame.lookAt(activeRoot.Position, flatActivationPosition)
            end
        elseif movement.mode == "overhead" or movement.mode == "hover" then
            local referencePosition = getHoverReferencePosition(targetPosition)
            local safePosition = safeOverheadPlatformPosition(
                referencePosition,
                activeCharacter,
                monster,
                movement.overheadPlatform
            )
            local platform = movement.overheadPlatform
            if movement.mode == "hover" and os.clock() - movement.lastPlatformRetryAt
                >= OVERHEAD_PLATFORM_RETRY_SECONDS then
                movement.lastPlatformRetryAt = os.clock()
                platform = createOverheadPlatform(safePosition)
                if platform then
                    movement.overheadPlatform = platform
                    movement.mode = "overhead"
                    print("[Vichop/Killer] Overhead platform recovered")
                end
            elseif movement.mode == "overhead" and (not platform or not platform.Parent) then
                movement.overheadPlatform = nil
                movement.mode = "hover"
                movement.lastPlatformRetryAt = 0
                warn("[Vichop/Killer] Overhead platform was removed; using safe hover fallback")
                platform = nil
            end

            if platform then
                platform.Position = smoothPlatformPosition(platform.Position, safePosition, deltaTime)
                local standingHeight = platform.Size.Y * 0.5 + activeHumanoid.HipHeight
                    + activeRoot.Size.Y * 0.5
                local standingPosition = platform.Position + Vector3.new(0, standingHeight, 0)
                local horizontalError = (Vector3.new(activeRoot.Position.X, 0, activeRoot.Position.Z)
                    - Vector3.new(platform.Position.X, 0, platform.Position.Z)).Magnitude
                local verticalError = math.abs(activeRoot.Position.Y - standingPosition.Y)
                if horizontalError > OVERHEAD_MAX_CORRECTION_DISTANCE
                    or verticalError > OVERHEAD_MAX_CORRECTION_DISTANCE then
                    movement.alignPosition.Enabled = true
                    movement.alignPosition.Position = standingPosition
                    activeHumanoid.AutoRotate = false
                    if not movement.noclipConnection then
                        enableTravelNoclip(activeCharacter)
                    end
                elseif horizontalError <= OVERHEAD_SETTLED_DISTANCE
                    and verticalError <= OVERHEAD_SETTLED_DISTANCE then
                    movement.alignPosition.Enabled = false
                    disableTravelNoclip()
                    activeHumanoid.AutoRotate = true
                end
            else
                movement.alignPosition.Enabled = true
                movement.alignPosition.MaxVelocity = OVERHEAD_FALLBACK_MAX_VELOCITY
                movement.alignPosition.Position = safePosition + Vector3.new(
                    0,
                    activeHumanoid.HipHeight + activeRoot.Size.Y * 0.5,
                    0
                )
                activeHumanoid.AutoRotate = false
                if not movement.noclipConnection then
                    enableTravelNoclip(activeCharacter)
                end
            end
        end
    end)
    print("[Vichop/Killer] Moving to confirmed Vicious Bee with AlignPosition")
    return true
end

local hud = { connections = {}, values = {} }

local function loadHudBackgroundAsset()
    local customAsset = type(getcustomasset) == "function" and getcustomasset
        or (type(getsynasset) == "function" and getsynasset or nil)
    if not customAsset or type(writefile) ~= "function" then
        return nil
    end

    local fileReady = false
    if type(isfile) == "function" then
        local ok, exists = pcall(isfile, HUD_BACKGROUND_FILE)
        fileReady = ok and exists == true
    elseif type(readfile) == "function" then
        fileReady = pcall(readfile, HUD_BACKGROUND_FILE)
    end

    if not fileReady then
        local ok, response = pcall(httpRequest, {
            Url = HUD_BACKGROUND_URL,
            Method = "GET",
            Timeout = HTTP_TIMEOUT_SECONDS,
        })
        local body = ok and response and (response.Body or response.body) or nil
        local status = ok and responseStatus(response) or 0
        if status >= 200 and status < 300 and type(body) == "string" and #body > 1024 then
            fileReady = pcall(writefile, HUD_BACKGROUND_FILE, body)
        end
    end

    if not fileReady then
        return nil
    end
    local ok, asset = pcall(customAsset, HUD_BACKGROUND_FILE)
    return ok and asset or nil
end

local function trackHudConnection(connection)
    table.insert(hud.connections, connection)
    return connection
end

local function newLabel(parent, name, position, size, text, textSize, color, font)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.Position = position
    label.Size = size
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = color
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Font = font or Enum.Font.GothamMedium
    label.TextSize = textSize
    label.Parent = parent
    return label
end

local function addStat(parent, key, caption, x, y)
    newLabel(
        parent,
        key .. "Caption",
        UDim2.fromOffset(x, y),
        UDim2.fromOffset(128, 14),
        string.upper(caption),
        10,
        Color3.fromRGB(119, 132, 125),
        Enum.Font.GothamMedium
    )
    hud.values[key] = newLabel(
        parent,
        key,
        UDim2.fromOffset(x, y + 14),
        UDim2.fromOffset(128, 24),
        "0",
        17,
        Color3.fromRGB(238, 244, 240),
        Enum.Font.GothamSemibold
    )
end

local function destroyHud()
    for _, connection in ipairs(hud.connections or {}) do
        pcall(connection.Disconnect, connection)
    end
    if hud.screenGui then
        pcall(hud.screenGui.Destroy, hud.screenGui)
    end
    hud = { connections = {}, values = {} }
end
runtime.destroyHud = destroyHud

local function createHud()
    local playerGui = PLAYER:FindFirstChildOfClass("PlayerGui") or PLAYER:WaitForChild("PlayerGui", 5)
    if not playerGui then
        warn("[Vichop/Killer] PlayerGui unavailable; using console notifications")
        return
    end
    local old = playerGui:FindFirstChild("VichopKillerHud")
    if old then
        old:Destroy()
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "VichopKillerHud"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 1000
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = playerGui
    hud.screenGui = screenGui

    local shadow = Instance.new("Frame")
    shadow.Name = "Shadow"
    shadow.AnchorPoint = Vector2.new(0.5, 0.5)
    shadow.Position = UDim2.new(0.5, 5, 0.5, 7)
    shadow.Size = UDim2.fromOffset(460, 300)
    shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    shadow.BackgroundTransparency = 0.42
    shadow.BorderSizePixel = 0
    shadow.Parent = screenGui
    local shadowCorner = Instance.new("UICorner")
    shadowCorner.CornerRadius = UDim.new(0, 8)
    shadowCorner.Parent = shadow

    local window = Instance.new("Frame")
    window.Name = "Window"
    window.AnchorPoint = Vector2.new(0.5, 0.5)
    window.Position = UDim2.fromScale(0.5, 0.5)
    window.Size = UDim2.fromOffset(460, 300)
    window.BackgroundColor3 = Color3.fromRGB(10, 13, 12)
    window.BackgroundTransparency = 0.04
    window.BorderSizePixel = 0
    window.ClipsDescendants = true
    window.Parent = screenGui
    hud.window = window

    local windowCorner = Instance.new("UICorner")
    windowCorner.CornerRadius = UDim.new(0, 8)
    windowCorner.Parent = window
    local windowStroke = Instance.new("UIStroke")
    windowStroke.Color = Color3.fromRGB(57, 255, 20)
    windowStroke.Thickness = 1.5
    windowStroke.Transparency = 0.2
    windowStroke.Parent = window

    local backgroundArtwork = Instance.new("ImageLabel")
    backgroundArtwork.Name = "BackgroundArtwork"
    backgroundArtwork.Size = UDim2.fromScale(1, 1)
    backgroundArtwork.BackgroundTransparency = 1
    backgroundArtwork.Image = ""
    backgroundArtwork.ImageColor3 = Color3.fromRGB(110, 110, 110)
    backgroundArtwork.ImageTransparency = 0.18
    backgroundArtwork.ScaleType = Enum.ScaleType.Crop
    backgroundArtwork.ZIndex = 1
    backgroundArtwork.Parent = window
    task.spawn(function()
        local asset = loadHudBackgroundAsset()
        if asset and backgroundArtwork.Parent then
            backgroundArtwork.Image = asset
        end
    end)

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 52)
    header.BackgroundColor3 = Color3.fromRGB(15, 20, 17)
    header.BackgroundTransparency = 0.12
    header.BorderSizePixel = 0
    header.Active = true
    header.Parent = window
    local headerCorner = Instance.new("UICorner")
    headerCorner.CornerRadius = UDim.new(0, 8)
    headerCorner.Parent = header

    local title = newLabel(
        header,
        "Title",
        UDim2.fromOffset(18, 0),
        UDim2.new(1, -150, 1, 0),
        "Vichop Made By Qitch",
        17,
        Color3.fromRGB(57, 255, 20),
        Enum.Font.GothamSemibold
    )
    title.TextStrokeTransparency = 0.35
    hud.title = title

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.AnchorPoint = Vector2.new(1, 0.5)
    status.Position = UDim2.new(1, -16, 0.5, 0)
    status.Size = UDim2.fromOffset(112, 26)
    status.BackgroundColor3 = Color3.fromRGB(22, 35, 26)
    status.BackgroundTransparency = 0.05
    status.BorderSizePixel = 0
    status.Text = runtime.state
    status.TextColor3 = Color3.fromRGB(97, 255, 120)
    status.Font = Enum.Font.GothamSemibold
    status.TextSize = 11
    status.Parent = header
    local statusCorner = Instance.new("UICorner")
    statusCorner.CornerRadius = UDim.new(1, 0)
    statusCorner.Parent = status
    hud.status = status

    local divider = Instance.new("Frame")
    divider.Position = UDim2.fromOffset(18, 52)
    divider.Size = UDim2.new(1, -36, 0, 1)
    divider.BackgroundColor3 = Color3.fromRGB(46, 56, 50)
    divider.BackgroundTransparency = 0.3
    divider.BorderSizePixel = 0
    divider.Parent = window

    addStat(window, "sessionKills", "Session kills", 20, 68)
    addStat(window, "totalKills", "Total kill", 166, 68)
    addStat(window, "stingersPerHour", "Stingers / hour", 312, 68)
    addStat(window, "sessionStingers", "Session stingers", 20, 116)
    addStat(window, "totalStingers", "Total stinger", 166, 116)
    addStat(window, "searchers", "Active searchers", 312, 116)

    newLabel(
        window,
        "LastCaption",
        UDim2.fromOffset(20, 165),
        UDim2.fromOffset(110, 14),
        "LAST RESULT",
        10,
        Color3.fromRGB(119, 132, 125),
        Enum.Font.GothamMedium
    )
    hud.lastResult = newLabel(
        window,
        "LastResult",
        UDim2.fromOffset(20, 179),
        UDim2.new(1, -40, 0, 24),
        runtime.lastResult,
        14,
        Color3.fromRGB(224, 232, 227),
        Enum.Font.GothamMedium
    )
    hud.detail = newLabel(
        window,
        "Detail",
        UDim2.fromOffset(20, 201),
        UDim2.new(1, -40, 0, 20),
        runtime.detail,
        11,
        Color3.fromRGB(126, 143, 133),
        Enum.Font.GothamMedium
    )

    newLabel(
        window,
        "SpeedCaption",
        UDim2.fromOffset(20, 229),
        UDim2.fromOffset(180, 18),
        "HIVE TWEEN SPEED",
        10,
        Color3.fromRGB(119, 132, 125),
        Enum.Font.GothamMedium
    )
    hud.speedValue = newLabel(
        window,
        "SpeedValue",
        UDim2.new(1, -120, 0, 226),
        UDim2.fromOffset(100, 22),
        tostring(math.floor(runtime.hiveTweenSpeed + 0.5)),
        13,
        Color3.fromRGB(97, 255, 120),
        Enum.Font.GothamSemibold
    )
    hud.speedValue.TextXAlignment = Enum.TextXAlignment.Right

    local sliderTrack = Instance.new("Frame")
    sliderTrack.Name = "SliderTrack"
    sliderTrack.Position = UDim2.fromOffset(20, 257)
    sliderTrack.Size = UDim2.new(1, -40, 0, 6)
    sliderTrack.BackgroundColor3 = Color3.fromRGB(40, 49, 44)
    sliderTrack.BorderSizePixel = 0
    sliderTrack.Parent = window
    local trackCorner = Instance.new("UICorner")
    trackCorner.CornerRadius = UDim.new(1, 0)
    trackCorner.Parent = sliderTrack

    local sliderFill = Instance.new("Frame")
    sliderFill.Name = "Fill"
    sliderFill.Size = UDim2.fromScale(0, 1)
    sliderFill.BackgroundColor3 = Color3.fromRGB(57, 255, 20)
    sliderFill.BorderSizePixel = 0
    sliderFill.Parent = sliderTrack
    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(1, 0)
    fillCorner.Parent = sliderFill
    hud.sliderFill = sliderFill

    local sliderKnob = Instance.new("Frame")
    sliderKnob.Name = "Knob"
    sliderKnob.AnchorPoint = Vector2.new(0.5, 0.5)
    sliderKnob.Position = UDim2.fromScale(0, 0.5)
    sliderKnob.Size = UDim2.fromOffset(16, 16)
    sliderKnob.BackgroundColor3 = Color3.fromRGB(235, 255, 239)
    sliderKnob.BorderSizePixel = 0
    sliderKnob.ZIndex = 3
    sliderKnob.Parent = sliderTrack
    local knobCorner = Instance.new("UICorner")
    knobCorner.CornerRadius = UDim.new(1, 0)
    knobCorner.Parent = sliderKnob
    local knobStroke = Instance.new("UIStroke")
    knobStroke.Color = Color3.fromRGB(57, 255, 20)
    knobStroke.Thickness = 2
    knobStroke.Parent = sliderKnob
    hud.sliderKnob = sliderKnob

    local sliderInput = Instance.new("TextButton")
    sliderInput.Name = "SliderInput"
    sliderInput.Position = UDim2.fromOffset(0, -10)
    sliderInput.Size = UDim2.new(1, 0, 1, 20)
    sliderInput.BackgroundTransparency = 1
    sliderInput.Text = ""
    sliderInput.ZIndex = 4
    sliderInput.Parent = sliderTrack

    for _, descendant in ipairs(window:GetDescendants()) do
        if descendant:IsA("GuiObject") and descendant ~= backgroundArtwork then
            descendant.ZIndex = math.max(descendant.ZIndex, 2)
        end
    end

    local function renderSpeed()
        local alpha = (runtime.hiveTweenSpeed - MIN_HIVE_APPROACH_SPEED)
            / (MAX_HIVE_APPROACH_SPEED - MIN_HIVE_APPROACH_SPEED)
        alpha = math.clamp(alpha, 0, 1)
        sliderFill.Size = UDim2.fromScale(alpha, 1)
        sliderKnob.Position = UDim2.fromScale(alpha, 0.5)
        hud.speedValue.Text = tostring(math.floor(runtime.hiveTweenSpeed + 0.5)) .. " studs/s"
    end
    local function setSpeedFromX(x)
        local width = math.max(sliderTrack.AbsoluteSize.X, 1)
        local alpha = math.clamp((x - sliderTrack.AbsolutePosition.X) / width, 0, 1)
        runtime.hiveTweenSpeed = math.floor(
            MIN_HIVE_APPROACH_SPEED + alpha * (MAX_HIVE_APPROACH_SPEED - MIN_HIVE_APPROACH_SPEED) + 0.5
        )
        env.VICHOP_HIVE_TWEEN_SPEED = runtime.hiveTweenSpeed
        saveHiveTweenSpeed(false)
        renderSpeed()
    end
    renderSpeed()

    local draggingWindow = false
    local draggingSlider = false
    local dragStart
    local windowStart
    trackHudConnection(header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            draggingWindow = true
            dragStart = input.Position
            windowStart = window.Position
        end
    end))
    trackHudConnection(sliderInput.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            draggingSlider = true
            setSpeedFromX(input.Position.X)
        end
    end))
    trackHudConnection(UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        if draggingWindow and dragStart and windowStart then
            local delta = input.Position - dragStart
            window.Position = UDim2.new(
                windowStart.X.Scale,
                windowStart.X.Offset + delta.X,
                windowStart.Y.Scale,
                windowStart.Y.Offset + delta.Y
            )
            shadow.Position = window.Position + UDim2.fromOffset(5, 7)
        elseif draggingSlider then
            setSpeedFromX(input.Position.X)
        end
    end))
    trackHudConnection(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            if draggingSlider then
                saveHiveTweenSpeed(true)
            end
            draggingWindow = false
            draggingSlider = false
        end
    end))
    trackHudConnection(RunService.RenderStepped:Connect(function()
        if not title.Parent then
            return
        end
        local phase = (math.sin(os.clock() * 1.8) + 1) * 0.5
        local neonGreen = Color3.fromRGB(57, 255, 20)
        local neonBlack = Color3.fromRGB(2, 8, 4)
        title.TextColor3 = neonGreen:Lerp(neonBlack, phase)
        title.TextStrokeColor3 = neonBlack:Lerp(neonGreen, phase)
    end))
end

local function updateHud()
    if not hud.screenGui or not hud.screenGui.Parent then
        return
    end
    hud.status.Text = runtime.state
    hud.values.sessionKills.Text = formatNumber(stats.sessionKills)
    hud.values.totalKills.Text = formatNumber(stats.totalKills)
    hud.values.sessionStingers.Text = formatNumber(stats.sessionStingers)
    hud.values.totalStingers.Text = formatNumber(stats.totalStingers)
    hud.values.stingersPerHour.Text = formatRate(sessionStingersPerHour())
    hud.values.searchers.Text = activeSearcherDisplay()
    hud.lastResult.Text = runtime.lastResult
    hud.detail.Text = runtime.detail .. "  |  " .. formatDuration(now() - stats.startedAt)
end

local function setState(state, detail)
    runtime.state = state or runtime.state
    runtime.detail = detail or runtime.detail
    updateHud()
end

local function isoTimestamp(timestamp)
    local ok, value = pcall(function()
        return DateTime.fromUnixTimestamp(timestamp):ToIsoDate()
    end)
    return ok and value or nil
end

local function webhookStingerText(report)
    if not report.stingersKnown then
        return "`Unknown`"
    end
    return "`+" .. formatNumber(report.stingersGained) .. "`"
end

local function webhookStingerInventoryText(report)
    if not report.stingersKnown then
        return "`Unknown`"
    end
    return "`" .. formatNumber(report.stingersBefore) .. " -> " .. formatNumber(report.finalStingerCount) .. "`"
end

local function sendWebhook(report)
    if DISCORD_WEBHOOK_URL == "" then
        return
    end
    local title = report.success and "Vicious Bee Defeated" or "Vicious Job Failed"
    local color = report.success and (report.stingersKnown and 5763719 or 16763904) or 15548997
    local statusText = report.status or (report.success and "Success" or "Failure")
    local payload = {
        username = WEBHOOK_USERNAME,
        avatar_url = WEBHOOK_AVATAR_URL ~= "" and WEBHOOK_AVATAR_URL or nil,
        embeds = {{
            title = title,
            color = color,
            timestamp = isoTimestamp(report.completedAt or now()),
            fields = {
                { name = "Status", value = "`" .. statusText .. "`", inline = true },
                { name = "Stingers gained", value = webhookStingerText(report), inline = true },
                { name = "Stinger inventory", value = webhookStingerInventoryText(report), inline = true },
                { name = "Vicious level", value = report.level and ("`" .. tostring(report.level) .. "`") or "`Unknown`", inline = true },
                { name = "Session kills", value = "`" .. formatNumber(stats.sessionKills) .. "`", inline = true },
                { name = "Session stingers", value = "`" .. formatNumber(stats.sessionStingers) .. "`", inline = true },
                { name = "Stingers / hour", value = "`" .. formatRate(sessionStingersPerHour()) .. "`", inline = true },
                { name = "Active searchers", value = "`" .. activeSearcherDisplay() .. "`", inline = true },
                { name = "Total Kill", value = "`" .. formatNumber(stats.totalKills) .. "`", inline = true },
                { name = "Total Stinger", value = "`" .. formatNumber(stats.totalStingers) .. "`", inline = true },
            },
            footer = { text = "Vichop Tracker | " .. formatDuration(now() - stats.startedAt) .. " session uptime" },
        }},
    }

    runtime.webhookInFlight = runtime.webhookInFlight + 1
    task.spawn(function()
        local ok, response = pcall(httpRequest, {
            Url = DISCORD_WEBHOOK_URL,
            Method = "POST",
            Timeout = HTTP_TIMEOUT_SECONDS,
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload),
        })
        runtime.webhookInFlight = math.max(0, runtime.webhookInFlight - 1)
        local status = ok and responseStatus(response) or 0
        if status < 200 or status >= 300 then
            warn("[Vichop/Killer] Discord webhook failed with status", status)
        else
            print("[Vichop/Killer] Discord outcome sent once for", shortJobId(report.jobId))
        end
    end)
end

local function claimIsFresh(job, timestamp)
    return type(job) == "table" and tonumber(job.claimExpiresAt or 0) >= timestamp
end

local function jobIsFresh(job, timestamp)
    local lastSeen = type(job) == "table" and tonumber(job.lastSeenAt or job.updatedAt or 0) or 0
    return lastSeen >= timestamp - JOB_FRESH_SECONDS
end

local function claimJob(key)
    local timestamp = now()
    return atomicMutate(jobPath(key), function(current)
        if type(current) ~= "table" or current.status ~= "spawned" then
            return nil, "not_spawned"
        end
        if tonumber(current.placeId) ~= game.PlaceId or tostring(current.jobId or key) ~= tostring(key) then
            return nil, "invalid_target"
        end
        if not jobIsFresh(current, timestamp) then
            return nil, "stale"
        end
        local updated = copyTable(current)
        updated.status = "claimed"
        updated.killer = KILLER_NAME
        updated.claimedBy = sessionId
        updated.claimedAt = timestamp
        updated.claimHeartbeatAt = timestamp
        updated.claimExpiresAt = timestamp + CLAIM_LEASE_SECONDS
        updated.updatedAt = timestamp
        return updated, "claimed"
    end, 5)
end

local function heartbeatClaim(key)
    local timestamp = now()
    local ok = atomicMutate(jobPath(key), function(current)
        if type(current) ~= "table" or current.status ~= "claimed" or current.claimedBy ~= sessionId then
            return nil, "ownership_lost"
        end
        local updated = copyTable(current)
        updated.claimHeartbeatAt = timestamp
        updated.claimExpiresAt = timestamp + CLAIM_LEASE_SECONDS
        updated.updatedAt = timestamp
        return updated, "heartbeat"
    end, 3)
    if ok then
        runtime.lastClaimHeartbeat = timestamp
    end
    return ok
end

local function transitionOwnedJob(key, fromStatus, toStatus, extra)
    local timestamp = now()
    return atomicMutate(jobPath(key), function(current)
        if type(current) ~= "table" or current.status ~= fromStatus or current.claimedBy ~= sessionId then
            return nil, "ownership_or_state_changed"
        end
        local updated = copyTable(current)
        updated.status = toStatus
        updated.updatedAt = timestamp
        for name, value in pairs(extra or {}) do
            updated[name] = value
        end
        return updated, "transitioned"
    end, 5)
end

local function reportFailure(key, job, reason, statusLabel, terminalStatus)
    local completedAt = now()
    terminalStatus = terminalStatus == "expired" and "expired" or "failed"
    local terminalData = {
        failureReason = reason,
        claimExpiresAt = completedAt,
    }
    terminalData[terminalStatus == "expired" and "expiredAt" or "failedAt"] = completedAt
    local transitioned = transitionOwnedJob(key, "claimed", terminalStatus, terminalData)
    if not transitioned then
        return false
    end
    runtime.failedJobs[key] = completedAt + 5 * 60
    runtime.lastResult = statusLabel or "Failed job"
    setState("SEARCHING", reason)
    sendWebhook({
        success = false,
        status = statusLabel or "Failure",
        stingersKnown = false,
        jobId = key,
        level = job and job.viciousLevel,
        searchDuration = job and (completedAt - tonumber(job.createdAt or completedAt)) or 0,
        killServerDuration = runtime.currentJoinedAt and (completedAt - runtime.currentJoinedAt) or 0,
        completedAt = completedAt,
    })
    return true
end

local function collectStingerResult(stingersBefore, key)
    local deadline = os.clock() + REWARD_MAX_SECONDS
    local attempt = 0
    local maxAfter = nil
    local lastAfter = nil
    local stableReads = 0

    print(
        "[Vichop/Killer][Stingers] before =",
        stingersBefore == nil and "Unknown" or stingersBefore,
        "source =",
        runtime.stingerSource
    )
    while runtime.active and os.clock() <= deadline do
        attempt = attempt + 1
        local after = game.JobId == key and getStingers() or nil
        print("[Vichop/Killer][Stingers] after attempt", attempt, "=", after == nil and "Unknown" or after)
        if after ~= nil then
            maxAfter = maxAfter == nil and after or math.max(maxAfter, after)
            if after == lastAfter then
                stableReads = stableReads + 1
            else
                stableReads = 1
                lastAfter = after
            end
            if stingersBefore ~= nil and after > stingersBefore and stableReads >= REWARD_STABLE_READS then
                break
            end
        else
            stableReads = 0
            lastAfter = nil
        end
        task.wait(REWARD_POLL_SECONDS)
    end

    if stingersBefore == nil or maxAfter == nil or game.JobId ~= key then
        print("[Vichop/Killer][Stingers] final = Unknown")
        return nil, nil, false
    end
    local gained = math.max(0, maxAfter - stingersBefore)
    print("[Vichop/Killer][Stingers] final before =", stingersBefore, "after =", maxAfter, "gained =", gained)
    return gained, maxAfter, true
end

local function waitForVicious()
    local deadline = os.clock() + ARRIVAL_WAIT_SECONDS
    while runtime.active and os.clock() <= deadline do
        local monster, humanoid, level = getVicious()
        if monster then
            return monster, humanoid, level
        end
        task.wait(0.2)
    end
    return nil, nil, nil
end

local function monitorConfirmedDeath(key, monster, humanoid)
    local deathSignaled = false
    local diedConnection = humanoid.Died:Connect(function()
        deathSignaled = true
    end)
    local stingersBefore = getStingers()
    print("[Vichop/Killer][Stingers] initial live baseline =", stingersBefore == nil and "Unknown" or stingersBefore)
    local deadline = os.clock() + MAX_HUNT_SECONDS
    local confirmed = false
    local failureReason = nil

    while runtime.active and os.clock() <= deadline do
        if game.JobId ~= key then
            failureReason = "wrong_server_during_hunt"
            break
        end
        if deathSignaled or humanoid.Health <= 0 then
            confirmed = true
            break
        end
        if not monster.Parent then
            failureReason = "vicious_disappeared_without_confirmed_death"
            break
        end

        local latest = getStingers()
        if latest ~= nil and latest ~= stingersBefore then
            stingersBefore = latest
            print("[Vichop/Killer][Stingers] refreshed live baseline =", stingersBefore)
        elseif latest ~= nil then
            stingersBefore = latest
        end
        if now() - runtime.lastClaimHeartbeat >= CLAIM_HEARTBEAT_SECONDS then
            if not heartbeatClaim(key) then
                failureReason = "claim_lease_lost"
                break
            end
        end
        setState("HUNTING", "Vicious Bee active")
        task.wait(HUNT_POLL_SECONDS)
    end

    diedConnection:Disconnect()
    if not confirmed and not failureReason then
        failureReason = "hunt_timeout"
    end
    return confirmed, stingersBefore, failureReason
end

local function recordConfirmedKill(key, job, level, stingersBefore)
    local resolvingAt = now()
    local resolving = transitionOwnedJob(key, "claimed", "resolving", {
        deathConfirmedAt = resolvingAt,
        viciousLevel = level or job.viciousLevel,
    })
    if not resolving then
        warn("[Vichop/Killer] Death confirmed, but this process no longer owns the job")
        return false
    end

    setState("REWARD", "Waiting for inventory update")
    local gained, finalStingers, known = collectStingerResult(stingersBefore, key)
    local completedAt = now()
    local eventId = tostring(job.eventId or (key .. ":" .. tostring(job.createdAt or 0)))
    local killedPayload = {
        killedAt = completedAt,
        killedInJobId = game.JobId,
        deathConfirmed = true,
        stingerStatus = known and "known" or "unknown",
        viciousLevel = level or job.viciousLevel,
        claimExpiresAt = completedAt,
    }
    if known then
        killedPayload.stingersBefore = stingersBefore
        killedPayload.finalStingerCount = finalStingers
        killedPayload.stingersGained = gained
    end

    local completed = transitionOwnedJob(key, "resolving", "killed", killedPayload)
    if not completed then
        warn("[Vichop/Killer] Could not finalize the resolved job; stats and webhook were not updated")
        return false
    end

    if stats.lastKillEventId ~= eventId then
        stats.totalKills = stats.totalKills + 1
        stats.sessionKills = stats.sessionKills + 1
        if known then
            stats.totalStingers = stats.totalStingers + gained
            stats.sessionStingers = stats.sessionStingers + gained
        end
        stats.lastKillEventId = eventId
        saveStats()
    end

    local rewardText = known and ("+" .. formatNumber(gained) .. " stingers") or "stingers Unknown"
    runtime.lastResult = "Kill: " .. rewardText
    setState("CONFIRMED", rewardText)
    notify("Vicious defeated", rewardText .. " | " .. formatNumber(stats.sessionKills) .. " session kills")
    sendWebhook({
        success = true,
        status = known and "Success" or "Success - reward unknown",
        stingersKnown = known,
        stingersGained = gained,
        stingersBefore = stingersBefore,
        finalStingerCount = finalStingers,
        jobId = key,
        level = level or job.viciousLevel,
        searchDuration = (runtime.currentJoinedAt or completedAt) - tonumber(job.createdAt or completedAt),
        killServerDuration = completedAt - (runtime.currentJoinedAt or completedAt),
        completedAt = completedAt,
    })
    return true
end

local function handleClaim(key, job)
    runtime.currentClaimKey = key
    runtime.currentJob = job
    runtime.currentJoinedAt = now()
    runtime.lastClaimHeartbeat = 0
    setState("ARRIVED", "Confirming live Vicious Bee")

    if tostring(key) ~= game.JobId then
        reportFailure(key, job, "joined_wrong_server", "Failure - wrong server")
        runtime.currentClaimKey = nil
        return false
    end

    if not heartbeatClaim(key) then
        warn("[Vichop/Killer] Claim lease was lost before arrival validation")
        runtime.currentClaimKey = nil
        return false
    end
    local monster, humanoid, level = waitForVicious()
    if not monster then
        reportFailure(key, job, "vicious_missing_before_arrival_confirmation", "Expired job", "expired")
        runtime.currentClaimKey = nil
        return false
    end

    job.viciousLevel = level or job.viciousLevel
    setState("HUNTING", "Live Vicious Bee confirmed")
    notify("Vichop arrived", "Live Vicious Bee confirmed in claimed server")
    startMovement(monster)
    local confirmed, stingersBefore, failureReason = monitorConfirmedDeath(key, monster, humanoid)
    stopMovement(confirmed and "vicious_defeated" or (failureReason or "hunt_ended"))
    if not confirmed then
        if runtime.emergencyRejoinActive then
            warn("[Vichop/Killer] Hunt paused for emergency rejoin; preserving the current claim")
            return false
        end
        reportFailure(key, job, failureReason or "unconfirmed_disappearance", "Failure - unconfirmed death")
        runtime.currentClaimKey = nil
        return false
    end

    local recorded = recordConfirmedKill(key, job, level, stingersBefore)
    runtime.currentClaimKey = nil
    runtime.currentJob = nil
    return recorded
end

local function getSpawnedJobs()
    local data = firebaseGet('/jobs.json?orderBy="status"&equalTo="spawned"&limitToFirst=50') or {}
    local timestamp = now()
    local jobs = {}
    for key, job in pairs(data) do
        local failedUntil = tonumber(runtime.failedJobs[key] or 0)
        if type(job) == "table" and tonumber(job.placeId) == game.PlaceId
            and jobIsFresh(job, timestamp) and failedUntil <= timestamp then
            table.insert(jobs, { key = key, job = job })
        elseif type(job) == "table" and not jobIsFresh(job, timestamp) then
            local staleKey = key
            runtime.failedJobs[staleKey] = timestamp + JOB_FRESH_SECONDS
            task.spawn(function()
                atomicMutate(jobPath(staleKey), function(current)
                    if type(current) ~= "table" or current.status ~= "spawned" or jobIsFresh(current, now()) then
                        return nil, "fresh_or_changed"
                    end
                    local updated = copyTable(current)
                    updated.status = "expired"
                    updated.reason = "job_heartbeat_expired"
                    updated.updatedAt = now()
                    return updated, "expired"
                end, 2)
            end)
        end
    end
    table.sort(jobs, function(a, b)
        return tonumber(a.job.createdAt or 0) < tonumber(b.job.createdAt or 0)
    end)
    return jobs
end

local function cleanupOldData()
    local data = firebaseGet("/jobs.json") or {}
    local timestamp = now()
    local deleted = 0
    for key, job in pairs(data) do
        if type(job) == "table" then
            if job.status == "claimed" and not claimIsFresh(job, timestamp) then
                atomicMutate(jobPath(key), function(current)
                    if type(current) ~= "table" or current.status ~= "claimed" or claimIsFresh(current, now()) then
                        return nil, "fresh_or_changed"
                    end
                    local updated = copyTable(current)
                    if jobIsFresh(current, now()) then
                        updated.status = "spawned"
                        updated.claimedBy = nil
                        updated.killer = nil
                        updated.claimedAt = nil
                        updated.claimHeartbeatAt = nil
                        updated.claimExpiresAt = nil
                        updated.reason = "stale_claim_released"
                    else
                        updated.status = "expired"
                        updated.reason = "stale_claim_and_job"
                    end
                    updated.updatedAt = now()
                    return updated, "recovered"
                end, 3)
            elseif job.status == "resolving" and tonumber(job.updatedAt or 0) < timestamp - CLAIM_LEASE_SECONDS then
                atomicMutate(jobPath(key), function(current)
                    if type(current) ~= "table" or current.status ~= "resolving"
                        or tonumber(current.updatedAt or 0) >= now() - CLAIM_LEASE_SECONDS then
                        return nil, "fresh_or_changed"
                    end
                    local updated = copyTable(current)
                    updated.status = "failed"
                    updated.failureReason = "stale_reward_resolution"
                    updated.updatedAt = now()
                    return updated, "failed"
                end, 3)
            elseif (job.status == "killed" or job.status == "failed" or job.status == "expired" or job.status == "missing")
                and tonumber(job.updatedAt or 0) < timestamp - TERMINAL_RETENTION_SECONDS and deleted < 20 then
                if atomicDeleteIf(jobPath(key), function(current)
                    return type(current) == "table"
                        and current.status == job.status
                        and tonumber(current.updatedAt or 0) < now() - TERMINAL_RETENTION_SECONDS
                end) then
                    deleted = deleted + 1
                end
            end
        end
    end
end

local function scheduleCleanup()
    if runtime.cleanupRunning then
        return
    end
    runtime.cleanupRunning = true
    task.spawn(function()
        local ok, err = pcall(cleanupOldData)
        runtime.cleanupRunning = false
        if not ok then
            warn("[Vichop/Killer] Cleanup failed:", tostring(err))
        end
    end)
end

local function brieflyDrainWebhook()
    local deadline = os.clock() + 1.25
    while runtime.webhookInFlight > 0 and os.clock() < deadline do
        task.wait(0.05)
    end
end

local function writeResumeContext(key, job)
    if type(writefile) ~= "function" then
        warn("[Vichop/Killer] Local resume file is unavailable; relying on TeleportData")
        return false
    end
    local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, {
        vichopRole = "killer",
        vichopSessionId = sessionId,
        vichopExpectedJobId = tostring(job.jobId or key),
        vichopClaimKey = tostring(key),
        vichopFromJobId = game.JobId,
        vichopRedirectCount = runtime.redirectCount,
        savedAt = now(),
    })
    if not encodeOk then
        warn("[Vichop/Killer] Could not encode local resume context")
        return false
    end
    local writeOk, writeError = pcall(writefile, RESUME_FILE, encoded)
    if not writeOk then
        warn("[Vichop/Killer] Could not save local resume context:", tostring(writeError))
    end
    return writeOk
end

local function writeEmergencyResumeContext(claimKey)
    if type(writefile) ~= "function" then
        return false
    end
    local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, {
        vichopRole = "killer",
        vichopSessionId = sessionId,
        vichopExpectedJobId = game.JobId,
        vichopClaimKey = tostring(claimKey or ""),
        vichopFromJobId = game.JobId,
        vichopEmergencyRejoin = true,
        vichopRedirectCount = runtime.redirectCount,
        savedAt = now(),
    })
    return encodeOk and pcall(writefile, RESUME_FILE, encoded)
end

local function waitForSearcherSlot(key, job)
    if job.searcherDeparting ~= true then
        return true, job
    end

    local deadline = os.clock() + SLOT_HANDOFF_TIMEOUT_SECONDS
    local current = job
    setState("WAITING_SLOT", "Searcher is releasing " .. shortJobId(key))
    while runtime.active and os.clock() < deadline do
        if now() - runtime.lastClaimHeartbeat >= CLAIM_HEARTBEAT_SECONDS and not heartbeatClaim(key) then
            return false, current, "claim lease lost while waiting for searcher slot"
        end

        local latest, readOk = firebaseGet(jobPath(key))
        if readOk and type(latest) == "table" then
            current = latest
            if current.status ~= "claimed" or current.claimedBy ~= sessionId then
                return false, current, "claim ownership lost while waiting for searcher slot"
            end
            local slotReadyAt = tonumber(current.slotReadyAt or 0) or 0
            if slotReadyAt > 0 and now() >= slotReadyAt then
                return true, current
            end
        end
        task.wait(SLOT_HANDOFF_POLL_SECONDS)
    end
    return false, current, "searcher slot handoff timed out"
end

local function teleportToClaim(key, job)
    for attempt = 1, TELEPORT_RETRIES do
        if not heartbeatClaim(key) then
            return false, "claim lease lost before teleport"
        end
        local slotReady, refreshedJob, slotError = waitForSearcherSlot(key, job)
        job = refreshedJob or job
        if not slotReady then
            return false, slotError
        end
        runtime.teleportStarted = false
        runtime.teleportError = nil
        writeResumeContext(key, job)
        brieflyDrainWebhook()
        setState("TELEPORTING", "Attempt " .. tostring(attempt) .. " to " .. shortJobId(key))

        local data = {
            vichopRole = "killer",
            vichopSessionId = sessionId,
            vichopExpectedJobId = tostring(job.jobId or key),
            vichopClaimKey = key,
            vichopFromJobId = game.JobId,
            vichopRedirectCount = runtime.redirectCount,
            vichopTeleportedAt = now(),
        }
        local ok, err = pcall(function()
            TeleportService:TeleportToPlaceInstance(
                tonumber(job.placeId),
                tostring(job.jobId or key),
                PLAYER,
                nil,
                data
            )
        end)
        if not ok then
            runtime.teleportError = tostring(err)
        end

        local deadline = os.clock() + TELEPORT_TIMEOUT_SECONDS
        while runtime.active and os.clock() < deadline do
            if runtime.teleportError or runtime.teleportStarted then
                break
            end
            task.wait(0.1)
        end
        if runtime.teleportStarted then
            return true
        end
        local reason = runtime.teleportError or "client remained in the same server"
        warn("[Vichop/Killer] Teleport attempt", attempt, "failed:", reason)
        if attempt < TELEPORT_RETRIES then
            task.wait(math.min(2, 0.5 * attempt))
        end
    end
    return false, runtime.teleportError or "teleport retries exhausted"
end

local function activateCoreRetryButton()
    local ok, activated = pcall(function()
        for _, descendant in ipairs(CoreGui:GetDescendants()) do
            if descendant:IsA("TextButton") and descendant.Visible then
                local text = string.lower(descendant.Text or "")
                if text == "retry" or text == "rejoin" then
                    if type(firesignal) == "function" then
                        pcall(firesignal, descendant.Activated)
                        pcall(firesignal, descendant.MouseButton1Click)
                    else
                        pcall(descendant.Activate, descendant)
                    end
                    return true
                end
            end
        end
        return false
    end)
    return ok and activated == true
end

local function beginEmergencyRejoin(errorMessage)
    if runtime.emergencyRejoinActive or runtime.teleportStarted or not runtime.active then
        return
    end
    runtime.emergencyRejoinActive = true
    stopMovement("connection_lost")
    setState("REJOINING", "Connection lost; rejoining current server")
    warn("[Vichop/Killer] Connection error detected; rejoining exact JobId:", tostring(errorMessage))
    task.spawn(function()
        local attempt = 0
        while env.__VICHOP_KILLER_RUNTIME == runtime and runtime.active and not runtime.teleportStarted do
            attempt = attempt + 1
            local claimKey = tostring(runtime.currentClaimKey or "")
            if claimKey ~= "" then
                pcall(heartbeatClaim, claimKey)
            end
            writeEmergencyResumeContext(claimKey)
            local teleportData = {
                vichopRole = "killer",
                vichopSessionId = sessionId,
                vichopExpectedJobId = game.JobId,
                vichopClaimKey = claimKey,
                vichopFromJobId = game.JobId,
                vichopEmergencyRejoin = true,
                vichopRedirectCount = runtime.redirectCount,
            }
            pcall(function()
                TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, PLAYER, nil, teleportData)
            end)
            task.wait(EMERGENCY_REJOIN_RETRY_SECONDS)
            if attempt % 3 == 0 and not runtime.teleportStarted then
                activateCoreRetryButton()
            end
        end
        runtime.emergencyRejoinActive = false
    end)
end

local disconnectConnection
pcall(function()
    disconnectConnection = GuiService.ErrorMessageChanged:Connect(function(message)
        local currentMessage = tostring(message or "")
        if currentMessage == "" then
            pcall(function()
                currentMessage = tostring(GuiService:GetErrorMessage() or "")
            end)
        end
        if currentMessage ~= "" then
            beginEmergencyRejoin(currentMessage)
        end
    end)
end)

local teleportConnection = TeleportService.TeleportInitFailed:Connect(function(player, result, message)
    if player == PLAYER and runtime.active then
        runtime.teleportError = tostring(result) .. ": " .. tostring(message)
    end
end)

local playerTeleportConnection = PLAYER.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started then
        runtime.teleportStarted = true
        runtime.active = false
        stopMovement("teleport")
        destroyHud()
    end
end)

local function getJobWithRetry(key, retrySeconds)
    local deadline = os.clock() + retrySeconds
    local attempt = 0
    while runtime.active and os.clock() < deadline do
        attempt = attempt + 1
        local job, readOk = firebaseGet(jobPath(key))
        if readOk then
            return job, true
        end
        setState("RECOVERING", "Waiting for Firebase claim read (attempt " .. tostring(attempt) .. ")")
        task.wait(math.min(2, 0.4 + attempt * 0.2))
    end
    return nil, false
end

local function recoverArrivalContext()
    if joinTeleportData.vichopRole ~= "killer" then
        return "none"
    end

    local expectedKey = tostring(joinTeleportData.vichopClaimKey or joinTeleportData.vichopExpectedJobId or "")
    if expectedKey == "" then
        return "none"
    end

    if expectedKey ~= game.JobId then
        local wrongJob, readOk = getJobWithRetry(expectedKey, ARRIVAL_COORDINATION_RETRY_SECONDS)
        if not readOk then
            warn("[Vichop/Killer] Could not verify the claimed destination after arrival; staying put")
            return "blocked"
        end
        if type(wrongJob) ~= "table" or wrongJob.status ~= "claimed" or wrongJob.claimedBy ~= sessionId then
            warn("[Vichop/Killer] Claimed destination is no longer owned; resuming queue")
            return "none"
        end

        if runtime.redirectCount >= MAX_WRONG_SERVER_REDIRECTS then
            reportFailure(expectedKey, wrongJob, "teleported_into_wrong_server", "Failure - wrong server")
            return "none"
        end

        runtime.redirectCount = runtime.redirectCount + 1
        warn(
            "[Vichop/Killer] Arrived in the wrong server; retrying exact destination",
            runtime.redirectCount,
            "of",
            MAX_WRONG_SERVER_REDIRECTS
        )
        local teleported, teleportError = teleportToClaim(expectedKey, wrongJob)
        if teleported then
            return "redirected"
        end
        if runtime.active and not runtime.emergencyRejoinActive then
            reportFailure(
                expectedKey,
                wrongJob,
                "teleport_retry_failed: " .. tostring(teleportError),
                "Failure - teleport"
            )
        end
        return "none"
    end

    local currentJob, readOk = getJobWithRetry(game.JobId, ARRIVAL_COORDINATION_RETRY_SECONDS)
    if not readOk then
        warn("[Vichop/Killer] Could not verify the current claim after arrival; staying put")
        return "blocked"
    end
    if type(currentJob) == "table" and currentJob.status == "claimed" and currentJob.claimedBy == sessionId then
        handleClaim(game.JobId, currentJob)
        return "handled"
    end
    if type(currentJob) == "table" and currentJob.status == "spawned" then
        local claimed, _, claimedJob = claimJob(game.JobId)
        if claimed then
            handleClaim(game.JobId, claimedJob)
            return "handled"
        end
    end
    warn("[Vichop/Killer] Expected claim was not present in this server; resuming queue")
    return "none"
end

local function runKiller()
    createHud()
    updateHud()
    task.spawn(function()
        while runtime.active do
            updateHud()
            task.wait(0.5)
        end
    end)
    task.spawn(function()
        while runtime.active do
            refreshActiveSearcherCount()
            task.wait(ACTIVE_SEARCHER_REFRESH_SECONDS)
        end
    end)

    print("[Vichop/Killer] Running", KILLER_NAME, "session", sessionId:sub(1, 18), "in", shortJobId(game.JobId))

    setState("HIVE", "Claiming an unoccupied hive")
    claimAvailableHive()

    local arrivalState = recoverArrivalContext()
    while runtime.active and arrivalState == "blocked" do
        task.wait(1)
        arrivalState = recoverArrivalContext()
    end

    local lastCleanup = 0
    while runtime.active do
        if runtime.emergencyRejoinActive then
            task.wait(0.5)
            continue
        end
        local claimedSomething = false
        for _, candidate in ipairs(getSpawnedJobs()) do
            local claimed, reason, claimedJob = claimJob(candidate.key)
            if claimed then
                claimedSomething = true
                runtime.redirectCount = 0
                runtime.currentClaimKey = candidate.key
                runtime.currentJob = claimedJob
                notify("Vichop found", "Claimed Vicious server " .. shortJobId(candidate.key))
                if candidate.key == game.JobId then
                    handleClaim(candidate.key, claimedJob)
                else
                    local teleported, teleportError = teleportToClaim(candidate.key, claimedJob)
                    if not teleported and runtime.active and not runtime.emergencyRejoinActive then
                        reportFailure(candidate.key, claimedJob, "teleport_failed: " .. tostring(teleportError), "Failure - teleport")
                        runtime.currentClaimKey = nil
                        runtime.currentJob = nil
                    end
                end
                break
            elseif reason == "stale" then
                runtime.failedJobs[candidate.key] = now() + JOB_FRESH_SECONDS
            end
        end

        if runtime.active and not claimedSomething then
            setState("SEARCHING", "No fresh Vicious jobs")
        end
        if runtime.active and now() - lastCleanup >= CLEANUP_INTERVAL_SECONDS then
            lastCleanup = now()
            scheduleCleanup()
        end
        if runtime.active then
            task.wait(QUEUE_POLL_SECONDS)
        end
    end
end

local function tracebackMessage(message)
    if debug and type(debug.traceback) == "function" then
        return debug.traceback(tostring(message))
    end
    return tostring(message)
end

local runOk, runError = xpcall(runKiller, tracebackMessage)
runtime.active = false
stopMovement(runOk and "runtime_finished" or "runtime_error")
destroyHud()
if not runOk then
    warn("[Vichop/Killer] Main loop stopped and can be restarted:", tostring(runError))
end

if teleportConnection then
    teleportConnection:Disconnect()
end
if playerTeleportConnection then
    playerTeleportConnection:Disconnect()
end
if disconnectConnection then
    disconnectConnection:Disconnect()
end
