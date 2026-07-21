-- Vichop killer: atomically claims live Vicious Bee jobs, confirms real deaths,
-- settles the live stinger reward, and reports one outcome per claimed event.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local StarterGui = game:GetService("StarterGui")

local DATABASE_URL = "https://bss-job-queue-7bf75-default-rtdb.firebaseio.com"
local LOADER_URL = "https://raw.githubusercontent.com/glitchreal/jjj/main/killer_support.lua"
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
local TELEPORT_TIMEOUT_SECONDS = 7
local TELEPORT_RETRIES = 3

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

local env = type(getgenv) == "function" and getgenv() or _G
local function getJoinTeleportData()
    local ok, joinData = pcall(PLAYER.GetJoinData, PLAYER)
    if ok and type(joinData) == "table" and type(joinData.TeleportData) == "table"
        and joinData.TeleportData.vichopRole == "killer" then
        return joinData.TeleportData
    end
    local pending = env.__VICHOP_KILLER_PENDING
    env.__VICHOP_KILLER_PENDING = nil
    if type(pending) == "table" and pending.vichopRole == "killer"
        and os.time() - tonumber(pending.queuedAt or 0) <= 60 then
        return pending
    end
    return {}
end

local joinTeleportData = getJoinTeleportData()
local previousRuntime = env.__VICHOP_KILLER_RUNTIME
if type(previousRuntime) == "table" and previousRuntime.active and previousRuntime.jobId == game.JobId then
    print("[Vichop/Killer] Already running in this server")
    return
end

local sessionId = joinTeleportData.vichopRole == "killer" and joinTeleportData.vichopSessionId
    or env.__VICHOP_KILLER_SESSION_ID
if type(sessionId) ~= "string" or sessionId == "" then
    sessionId = "killer-" .. tostring(PLAYER.UserId) .. "-" .. HttpService:GenerateGUID(false)
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
}
env.__VICHOP_KILLER_RUNTIME = runtime

local KILLER_NAME = PLAYER.Name
local DISCORD_WEBHOOK_URL = type(env.VICHOP_WEBHOOK_URL) == "string" and env.VICHOP_WEBHOOK_URL or ""
local WEBHOOK_USERNAME = "Vichop Tracker"
local WEBHOOK_AVATAR_URL = ""
local httpRequest = request or http_request or (syn and syn.request)
if type(httpRequest) ~= "function" then
    warn("[Vichop/Killer] Disabled: executor HTTP requests are unavailable")
    runtime.active = false
    return
end
local queueOnTeleport = queue_on_teleport or (syn and syn.queue_on_teleport)

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

    if saved.sessionId == sessionId then
        for _, key in ipairs({ "sessionKills", "sessionStingers", "sessionJoins" }) do
            stats[key] = math.max(0, tonumber(saved[key]) or 0)
        end
        stats.startedAt = tonumber(saved.startedAt) or now()
    end
    return stats
end

local stats = loadStats()

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

local function getStingers()
    local coreStats = PLAYER:FindFirstChild("CoreStats")
    local stingers = coreStats and coreStats:FindFirstChild("Stingers")
    if stingers and (stingers:IsA("IntValue") or stingers:IsA("NumberValue")) then
        return tonumber(stingers.Value)
    end
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

local hud = {}
local function createHud()
    if not Drawing or type(Drawing.new) ~= "function" then
        return
    end
    local ok = pcall(function()
        hud.background = Drawing.new("Square")
        hud.background.Color = Color3.fromRGB(15, 18, 23)
        hud.background.Transparency = 0.12
        hud.background.Filled = true
        hud.background.Size = Vector2.new(330, 192)
        hud.background.Position = Vector2.new(18, 190)
        hud.background.Visible = true

        hud.accent = Drawing.new("Square")
        hud.accent.Color = Color3.fromRGB(245, 181, 46)
        hud.accent.Transparency = 0
        hud.accent.Filled = true
        hud.accent.Size = Vector2.new(4, 192)
        hud.accent.Position = Vector2.new(18, 190)
        hud.accent.Visible = true

        hud.title = Drawing.new("Text")
        hud.title.Color = Color3.fromRGB(255, 219, 121)
        hud.title.Size = 18
        hud.title.Font = 2
        hud.title.Position = Vector2.new(34, 201)
        hud.title.Visible = true

        hud.body = Drawing.new("Text")
        hud.body.Color = Color3.fromRGB(228, 232, 238)
        hud.body.Size = 15
        hud.body.Font = 2
        hud.body.Position = Vector2.new(34, 229)
        hud.body.Visible = true
    end)
    if not ok then
        hud = {}
        warn("[Vichop/Killer] Drawing tracker could not be created; using console notifications")
    end
end

local function updateHud()
    if not hud.title then
        return
    end
    hud.title.Text = "VICHOP  |  " .. runtime.state
    hud.body.Text = string.format(
        "Kills       %s session  |  %s lifetime\nStingers    %s session  |  %s lifetime\nServers     %s session  |  %s lifetime\nServer      %s\nState       %s\nLast        %s\nUptime      %s",
        formatNumber(stats.sessionKills), formatNumber(stats.totalKills),
        formatNumber(stats.sessionStingers), formatNumber(stats.totalStingers),
        formatNumber(stats.sessionJoins), formatNumber(stats.totalJoins),
        shortJobId(game.JobId), runtime.detail, runtime.lastResult,
        formatDuration(now() - stats.startedAt)
    )
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
                { name = "Killer", value = "`" .. KILLER_NAME .. "`", inline = true },
                { name = "Server ID", value = "`" .. shortJobId(report.jobId) .. "`", inline = true },
                { name = "Stingers gained", value = webhookStingerText(report), inline = true },
                { name = "Vicious level", value = report.level and ("`" .. tostring(report.level) .. "`") or "`Unknown`", inline = true },
                { name = "Search / hop", value = "`" .. formatDuration(report.searchDuration) .. "`", inline = true },
                { name = "Session kills", value = "`" .. formatNumber(stats.sessionKills) .. "`", inline = true },
                { name = "Session stingers", value = "`" .. formatNumber(stats.sessionStingers) .. "`", inline = true },
                { name = "Servers joined", value = "`" .. formatNumber(stats.sessionJoins) .. "`", inline = true },
                { name = "Lifetime kills", value = "`" .. formatNumber(stats.totalKills) .. "`", inline = true },
                { name = "Lifetime stingers", value = "`" .. formatNumber(stats.totalStingers) .. "`", inline = true },
                { name = "Kill server time", value = "`" .. formatDuration(report.killServerDuration) .. "`", inline = true },
            },
            footer = { text = "Vichop Tracker | " .. formatDuration(now() - stats.startedAt) .. " session uptime" },
        }},
    }

    runtime.webhookInFlight = runtime.webhookInFlight + 1
    task.spawn(function()
        local ok, response = pcall(httpRequest, {
            Url = DISCORD_WEBHOOK_URL,
            Method = "POST",
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

    print("[Vichop/Killer][Stingers] before =", stingersBefore == nil and "Unknown" or stingersBefore)
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
    local confirmed, stingersBefore, failureReason = monitorConfirmedDeath(key, monster, humanoid)
    if not confirmed then
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

local function queueLoader(key, job)
    if type(queueOnTeleport) ~= "function" then
        return
    end
    local loader = string.format(
        'local e=(getgenv and getgenv() or _G);e.__VICHOP_KILLER_SESSION_ID=%q;e.__VICHOP_KILLER_PENDING={vichopRole="killer",vichopSessionId=%q,vichopExpectedJobId=%q,vichopClaimKey=%q,vichopFromJobId=%q,queuedAt=%d};loadstring(game:HttpGet("%s?t=" .. os.time()))()',
        sessionId,
        sessionId,
        tostring(job.jobId or key),
        tostring(key),
        game.JobId,
        now(),
        LOADER_URL
    )
    local ok, err = pcall(queueOnTeleport, loader)
    if not ok then
        warn("[Vichop/Killer] Could not queue loader for teleport:", tostring(err))
    end
end

local function teleportToClaim(key, job)
    for attempt = 1, TELEPORT_RETRIES do
        if not heartbeatClaim(key) then
            return false, "claim lease lost before teleport"
        end
        runtime.teleportStarted = false
        runtime.teleportError = nil
        queueLoader(key, job)
        brieflyDrainWebhook()
        setState("TELEPORTING", "Attempt " .. tostring(attempt) .. " to " .. shortJobId(key))

        local data = {
            vichopRole = "killer",
            vichopSessionId = sessionId,
            vichopExpectedJobId = tostring(job.jobId or key),
            vichopClaimKey = key,
            vichopFromJobId = game.JobId,
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

local teleportConnection = TeleportService.TeleportInitFailed:Connect(function(player, result, message)
    if player == PLAYER and runtime.active then
        runtime.teleportError = tostring(result) .. ": " .. tostring(message)
    end
end)

local playerTeleportConnection = PLAYER.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started then
        runtime.teleportStarted = true
        runtime.active = false
    end
end)

local function runKiller()
    createHud()
    updateHud()
    task.spawn(function()
        while runtime.active do
            updateHud()
            task.wait(0.5)
        end
    end)

    print("[Vichop/Killer] Running", KILLER_NAME, "session", sessionId:sub(1, 18), "in", shortJobId(game.JobId))

    if joinTeleportData.vichopRole == "killer" and joinTeleportData.vichopExpectedJobId
        and tostring(joinTeleportData.vichopExpectedJobId) ~= game.JobId then
        local wrongKey = tostring(joinTeleportData.vichopClaimKey or joinTeleportData.vichopExpectedJobId)
        local wrongJob = firebaseGet(jobPath(wrongKey))
        if type(wrongJob) == "table" and wrongJob.status == "claimed" and wrongJob.claimedBy == sessionId then
            reportFailure(wrongKey, wrongJob, "teleported_into_wrong_server", "Failure - wrong server")
        end
    end

    local currentJob = firebaseGet(jobPath(game.JobId))
    if type(currentJob) == "table" and currentJob.status == "claimed" and currentJob.claimedBy == sessionId then
        handleClaim(game.JobId, currentJob)
    end

    local lastCleanup = 0
    while runtime.active do
        local claimedSomething = false
        for _, candidate in ipairs(getSpawnedJobs()) do
            local claimed, reason, claimedJob = claimJob(candidate.key)
            if claimed then
                claimedSomething = true
                runtime.currentClaimKey = candidate.key
                runtime.currentJob = claimedJob
                notify("Vichop found", "Claimed Vicious server " .. shortJobId(candidate.key))
                if candidate.key == game.JobId then
                    handleClaim(candidate.key, claimedJob)
                else
                    local teleported, teleportError = teleportToClaim(candidate.key, claimedJob)
                    if not teleported and runtime.active then
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
if not runOk then
    warn("[Vichop/Killer] Main loop stopped and can be restarted:", tostring(runError))
end

if teleportConnection then
    teleportConnection:Disconnect()
end
if playerTeleportConnection then
    playerTeleportConnection:Disconnect()
end
