-- Vichop searcher: reserves public servers, publishes live Vicious Bee jobs,
-- and moves on as soon as the current server is no longer useful.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local BSS_PLACE_ID = 1537690962
local DATABASE_URL = "https://bss-job-queue-7bf75-default-rtdb.firebaseio.com"
local INITIAL_SCAN_SECONDS = 5
local SCAN_INTERVAL_SECONDS = 0.25
local HEARTBEAT_SECONDS = 5
local RESERVATION_TTL_SECONDS = 20
local OWN_RECENT_TTL_SECONDS = 10 * 60
local FLEET_RECENT_TTL_SECONDS = 45
local JOB_STALE_SECONDS = 35
local CLEANUP_INTERVAL_SECONDS = 30
local TELEPORT_TIMEOUT_SECONDS = 7
local TELEPORT_BACKOFF_MAX_SECONDS = 3
local COLLISION_JITTER_AFTER = 3
local CHARACTER_READY_TIMEOUT_SECONDS = 30
local CHARACTER_SETTLE_SECONDS = 2

if game.PlaceId ~= BSS_PLACE_ID then
    return
end

local playerDeadline = os.clock() + 30
while not Players.LocalPlayer and os.clock() < playerDeadline do
    task.wait(0.1)
end
local PLAYER = Players.LocalPlayer
if not PLAYER then
    warn("[Vichop/Searcher] LocalPlayer is unavailable")
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
    warn("[Vichop/Searcher] Character did not become ready")
    return
end
task.wait(CHARACTER_SETTLE_SECONDS)
local RESUME_FILE = "vichop_searcher_resume_" .. tostring(PLAYER.UserId) .. ".json"

local env = type(getgenv) == "function" and getgenv() or _G
local previousRuntime = env.__VICHOP_SEARCHER_RUNTIME
if type(previousRuntime) == "table" and previousRuntime.active and previousRuntime.jobId == game.JobId then
    print("[Vichop/Searcher] Already running in this server")
    return
end

local runtime = {
    active = true,
    jobId = game.JobId,
    generation = HttpService:GenerateGUID(false),
    hopping = false,
    hopRequested = false,
    teleportControllerRunning = false,
    teleportStarted = false,
    teleportError = nil,
    currentReservationOwned = false,
    cleanupRunning = false,
    rehopCount = 0,
    previousJobId = "",
    arrivalStatus = "pending",
}
env.__VICHOP_SEARCHER_RUNTIME = runtime

local configuredSearcherId = env.VICHOP_SEARCHER_ID
local SEARCHER_ID = type(configuredSearcherId) == "string" and configuredSearcherId ~= ""
    and configuredSearcherId
    or ("searcher-" .. tostring(PLAYER.UserId))
env.VICHOP_SEARCHER_ID = SEARCHER_ID
local httpRequest = request or http_request or (syn and syn.request)
if type(httpRequest) ~= "function" then
    warn("[Vichop/Searcher] Disabled: executor HTTP requests are unavailable")
    runtime.active = false
    return
end

local currentJobEventId = nil
local lastJobHeartbeat = 0
local lastCleanup = 0
local serverStartedAtClock = os.clock()

local function now()
    return os.time()
end

local function readResumeContext()
    if type(isfile) ~= "function" or type(readfile) ~= "function" or not isfile(RESUME_FILE) then
        return nil
    end
    local readOk, raw = pcall(readfile, RESUME_FILE)
    if not readOk or type(raw) ~= "string" then
        return nil
    end
    local decodeOk, saved = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decodeOk or type(saved) ~= "table" or saved.vichopRole ~= "searcher"
        or now() - tonumber(saved.savedAt or 0) > 120 then
        return nil
    end
    return saved
end

local function writeResumeContext(previousJobId)
    if type(writefile) ~= "function" then
        warn("[Vichop/Searcher] Local resume file is unavailable; relying on TeleportData")
        return false
    end
    local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, {
        vichopRole = "searcher",
        vichopSearcherId = SEARCHER_ID,
        vichopPreviousJobId = previousJobId,
        vichopFromJobId = previousJobId,
        vichopRehopCount = runtime.rehopCount,
        savedAt = now(),
    })
    if not encodeOk then
        warn("[Vichop/Searcher] Could not encode local resume context")
        return false
    end
    local writeOk, writeError = pcall(writefile, RESUME_FILE, encoded)
    if not writeOk then
        warn("[Vichop/Searcher] Could not save local resume context:", tostring(writeError))
    end
    return writeOk
end

local function runtimeIsCurrent()
    return runtime.active and env.__VICHOP_SEARCHER_RUNTIME == runtime
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
        warn("[Vichop/Searcher] HTTP request failed:", tostring(response))
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
        warn("[Vichop/Searcher] Could not decode an HTTP response")
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
            warn("[Vichop/Searcher] Could not encode Firebase payload for", path)
            return nil, 0, false
        end
        options.Body = encoded
    end
    local response, status = rawRequest(options)
    if status < 200 or status >= 300 then
        if status ~= 412 then
            warn("[Vichop/Searcher] Firebase request failed:", method, path, status)
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

local function firebaseWrite(method, path, body)
    local _, _, ok = firebaseRequest(method, path, body)
    return ok
end

local function firebaseGetWithEtag(path)
    local response, _, ok = firebaseRequest("GET", path, nil, { ["X-Firebase-ETag"] = "true" })
    if not ok then
        return nil, nil, false
    end
    local value, decodedOk = decodeBody(response)
    local etag = responseHeader(response, "etag")
    if not decodedOk or not etag then
        warn("[Vichop/Searcher] Atomic Firebase operation unavailable for", path)
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

local function reservationPath(jobId)
    return "/activeServers/" .. tostring(jobId) .. ".json"
end

local function reservationIsFresh(reservation, timestamp)
    return type(reservation) == "table"
        and tonumber(reservation.heartbeatAt or 0) >= timestamp - RESERVATION_TTL_SECONDS
end

local function reserveServer(jobId)
    local timestamp = now()
    local claimedAt = timestamp
    local ok, reason = atomicMutate(reservationPath(jobId), function(current)
        if reservationIsFresh(current, timestamp) and current.searcherId ~= SEARCHER_ID then
            return nil, "occupied"
        end
        if type(current) == "table" and current.searcherId == SEARCHER_ID then
            claimedAt = tonumber(current.claimedAt) or timestamp
        end
        return {
            searcherId = SEARCHER_ID,
            searcherName = PLAYER.Name,
            claimedAt = claimedAt,
            heartbeatAt = timestamp,
            placeId = game.PlaceId,
        }, "reserved"
    end)
    return ok, reason
end

local function heartbeatReservation(jobId)
    local timestamp = now()
    return atomicMutate(reservationPath(jobId), function(current)
        if type(current) ~= "table" or current.searcherId ~= SEARCHER_ID then
            return nil, "ownership_lost"
        end
        local updated = copyTable(current)
        updated.heartbeatAt = timestamp
        updated.placeId = game.PlaceId
        return updated, "heartbeat"
    end, 3)
end

local function releaseReservation(jobId)
    return atomicDeleteIf(reservationPath(jobId), function(current)
        return type(current) == "table" and current.searcherId == SEARCHER_ID
    end)
end

local function markVisited(jobId)
    local timestamp = now()
    task.spawn(function()
        firebaseWrite("PUT", "/recentServers/" .. SEARCHER_ID .. "/" .. tostring(jobId) .. ".json", timestamp)
        firebaseWrite("PUT", "/fleetRecent/" .. tostring(jobId) .. ".json", {
            searcherId = SEARCHER_ID,
            checkedAt = timestamp,
            placeId = game.PlaceId,
        })
    end)
end

local function getVicious()
    local monsters = workspace:FindFirstChild("Monsters")
    if not monsters then
        return nil, nil
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
                return monster, level
            end
        end
    end
    return nil, nil
end

local function jobPath(jobId)
    return "/jobs/" .. tostring(jobId) .. ".json"
end

local function publishSpawn(monster, level)
    local timestamp = now()
    local eventId = game.JobId .. ":" .. tostring(timestamp)
    local ok, reason, saved = atomicMutate(jobPath(game.JobId), function(current)
        local status = type(current) == "table" and tostring(current.status or "") or ""
        if status == "claimed" or status == "resolving" then
            local updated = copyTable(current)
            updated.searcherHeartbeatAt = timestamp
            updated.lastSeenAt = timestamp
            updated.updatedAt = timestamp
            updated.note = monster:GetFullName()
            if level then
                updated.viciousLevel = level
            end
            return updated, "already_claimed"
        end
        if status == "spawned" and tonumber(current.lastSeenAt or current.updatedAt or 0) >= timestamp - JOB_STALE_SECONDS then
            eventId = tostring(current.eventId or eventId)
        end
        return {
            placeId = game.PlaceId,
            jobId = game.JobId,
            eventId = eventId,
            status = "spawned",
            createdAt = status == "spawned" and (tonumber(current.createdAt) or timestamp) or timestamp,
            updatedAt = timestamp,
            lastSeenAt = timestamp,
            searcherHeartbeatAt = timestamp,
            source = PLAYER.Name,
            searcherId = SEARCHER_ID,
            note = monster:GetFullName(),
            viciousLevel = level,
        }, "spawned"
    end)
    if ok then
        currentJobEventId = tostring(saved.eventId or eventId)
        lastJobHeartbeat = timestamp
        print("[Vichop/Searcher] Published live Vicious job", shortJobId(game.JobId), reason)
    end
    return ok
end

local function heartbeatJob(monster, level)
    local timestamp = now()
    local ok = atomicMutate(jobPath(game.JobId), function(current)
        if type(current) ~= "table" or tostring(current.eventId or "") ~= tostring(currentJobEventId or "") then
            return nil, "job_replaced"
        end
        if current.status ~= "spawned" and current.status ~= "claimed" then
            return nil, "terminal"
        end
        local updated = copyTable(current)
        updated.updatedAt = timestamp
        updated.lastSeenAt = timestamp
        updated.searcherHeartbeatAt = timestamp
        updated.note = monster:GetFullName()
        if level then
            updated.viciousLevel = level
        end
        return updated, "heartbeat"
    end, 3)
    if ok then
        lastJobHeartbeat = timestamp
    end
end

local function reportMissing()
    local timestamp = now()
    atomicMutate(jobPath(game.JobId), function(current)
        if type(current) ~= "table" or tostring(current.eventId or "") ~= tostring(currentJobEventId or "") then
            return nil, "job_replaced"
        end
        local updated = copyTable(current)
        updated.updatedAt = timestamp
        updated.searcherReportedMissingAt = timestamp
        if current.status == "spawned" then
            updated.status = "missing"
            updated.reason = "vicious_disappeared_before_claim"
        elseif current.status ~= "claimed" and current.status ~= "resolving" then
            return nil, "terminal"
        end
        return updated, "reported_missing"
    end, 3)
end

local function matchmakingTeleportData(previousJobId)
    return {
        vichopRole = "searcher",
        vichopSearcherId = SEARCHER_ID,
        vichopPreviousJobId = previousJobId,
        vichopFromJobId = previousJobId,
        vichopRehopCount = runtime.rehopCount,
        vichopTeleportedAt = now(),
    }
end

local function genericTeleportOnce(reason, requestedAt, attempt)
    runtime.teleportError = nil
    runtime.teleportStarted = false
    writeResumeContext(game.JobId)

    local ok, err = pcall(function()
        local callLatency = os.clock() - requestedAt
        print(string.format(
            "[Vichop/Searcher] Matchmaking teleport call latency %.3fs | reason=%s | attempt=%d",
            callLatency,
            tostring(reason),
            attempt
        ))
        TeleportService:Teleport(game.PlaceId, PLAYER, matchmakingTeleportData(game.JobId))
    end)
    if not ok then
        return false, tostring(err)
    end

    local deadline = os.clock() + TELEPORT_TIMEOUT_SECONDS
    while runtimeIsCurrent() and os.clock() < deadline do
        if runtime.teleportError then
            return false, runtime.teleportError
        end
        if runtime.teleportStarted then
            return true
        end
        task.wait(0.1)
    end
    if runtime.teleportStarted then
        return true
    end
    return false, "client remained in the same server"
end

local function hopServer(reason, requestedAt)
    if runtime.teleportControllerRunning or not runtimeIsCurrent() then
        return
    end
    runtime.teleportControllerRunning = true
    runtime.hopping = true

    if runtime.currentReservationOwned then
        runtime.currentReservationOwned = false
        task.spawn(releaseReservation, game.JobId)
    end

    if runtime.rehopCount >= COLLISION_JITTER_AFTER then
        task.wait(0.1 + math.random() * 0.3)
    end

    local attempt = 0
    local lastError = nil
    while runtimeIsCurrent() do
        attempt = attempt + 1
        local attemptRequestedAt = attempt == 1 and requestedAt or os.clock()
        local teleported, teleportError = genericTeleportOnce(reason, attemptRequestedAt, attempt)
        if teleported then
            return
        end

        if teleportError ~= lastError or attempt == 1 or attempt % 5 == 0 then
            warn("[Vichop/Searcher] Matchmaking teleport failed; retrying:", tostring(teleportError))
            lastError = teleportError
        end
        local backoff = math.min(TELEPORT_BACKOFF_MAX_SECONDS, 0.5 * (2 ^ math.min(attempt - 1, 3)))
        task.wait(backoff)
    end
    runtime.hopping = false
    runtime.teleportControllerRunning = false
end

local function requestHop(reason, isRehop)
    if runtime.hopping or runtime.hopRequested or runtime.teleportControllerRunning or not runtimeIsCurrent() then
        return
    end
    if not isRehop then
        runtime.rehopCount = 0
    end
    local requestedAt = os.clock()
    runtime.hopRequested = true
    task.spawn(function()
        if not runtimeIsCurrent() then
            return
        end
        runtime.hopRequested = false
        hopServer(reason, requestedAt)
    end)
end

local function validateArrivedServer(teleportContext)
    local previousJobId = type(teleportContext) == "table"
        and tostring(teleportContext.vichopPreviousJobId or teleportContext.vichopFromJobId or "") or ""
    if previousJobId ~= "" and previousJobId == game.JobId then
        return false, "matchmaking returned the previous server"
    end

    local ownRecent, ownRecentOk = firebaseGet("/recentServers/" .. SEARCHER_ID .. ".json")
    local fleetRecent, fleetRecentOk = firebaseGet("/fleetRecent.json")
    if not ownRecentOk or not fleetRecentOk then
        return false, "recent-server history unavailable"
    end

    local timestamp = now()
    local ownVisitedAt = tonumber(type(ownRecent) == "table" and ownRecent[game.JobId] or 0) or 0
    if ownVisitedAt >= timestamp - OWN_RECENT_TTL_SECONDS then
        return false, "server was recently checked by this searcher"
    end
    local fleetRecord = type(fleetRecent) == "table" and fleetRecent[game.JobId] or nil
    local fleetVisitedAt = type(fleetRecord) == "table" and fleetRecord.checkedAt or fleetRecord
    if tonumber(fleetVisitedAt or 0) >= timestamp - FLEET_RECENT_TTL_SECONDS then
        return false, "server was recently checked by the fleet"
    end

    local reserved, reserveReason = reserveServer(game.JobId)
    if not reserved then
        return false, "reservation rejected: " .. tostring(reserveReason)
    end
    runtime.currentReservationOwned = true
    runtime.rehopCount = 0
    markVisited(game.JobId)
    return true, "reserved"
end

local function expireOldData()
    local timestamp = now()
    local activeServers = firebaseGet("/activeServers.json") or {}
    local removed = 0
    for jobId, reservation in pairs(activeServers) do
        if removed >= 12 then
            break
        end
        if not reservationIsFresh(reservation, timestamp) then
            if atomicDeleteIf(reservationPath(jobId), function(current)
                return not reservationIsFresh(current, now())
            end) then
                removed = removed + 1
            end
        end
    end

    local jobs = firebaseGet("/jobs.json") or {}
    for jobId, job in pairs(jobs) do
        local status = type(job) == "table" and job.status or nil
        local lastSeen = type(job) == "table" and tonumber(job.lastSeenAt or job.updatedAt or 0) or 0
        if status == "spawned" and lastSeen < timestamp - JOB_STALE_SECONDS then
            atomicMutate(jobPath(jobId), function(current)
                local currentSeen = type(current) == "table" and tonumber(current.lastSeenAt or current.updatedAt or 0) or 0
                if type(current) ~= "table" or current.status ~= "spawned" or currentSeen >= now() - JOB_STALE_SECONDS then
                    return nil, "fresh_or_changed"
                end
                local updated = copyTable(current)
                updated.status = "expired"
                updated.reason = "searcher_heartbeat_expired"
                updated.updatedAt = now()
                return updated, "expired"
            end, 2)
        end
    end

    local ownRecent = firebaseGet("/recentServers/" .. SEARCHER_ID .. ".json") or {}
    for jobId, visitedAt in pairs(ownRecent) do
        if tonumber(visitedAt or 0) < timestamp - OWN_RECENT_TTL_SECONDS then
            atomicDeleteIf("/recentServers/" .. SEARCHER_ID .. "/" .. tostring(jobId) .. ".json", function(current)
                return tonumber(current or 0) < now() - OWN_RECENT_TTL_SECONDS
            end)
        end
    end

    local fleetRecent = firebaseGet("/fleetRecent.json") or {}
    for jobId, record in pairs(fleetRecent) do
        local checkedAt = type(record) == "table" and record.checkedAt or record
        if tonumber(checkedAt or 0) < timestamp - OWN_RECENT_TTL_SECONDS then
            atomicDeleteIf("/fleetRecent/" .. tostring(jobId) .. ".json", function(current)
                local currentCheckedAt = type(current) == "table" and current.checkedAt or current
                return tonumber(currentCheckedAt or 0) < now() - OWN_RECENT_TTL_SECONDS
            end)
        end
    end
end

local function scheduleCleanup()
    if runtime.cleanupRunning then
        return
    end
    runtime.cleanupRunning = true
    task.spawn(function()
        local ok, err = pcall(expireOldData)
        runtime.cleanupRunning = false
        if not ok then
            warn("[Vichop/Searcher] Cleanup failed:", tostring(err))
        end
    end)
end

local function getJoinTeleportData()
    local ok, joinData = pcall(PLAYER.GetJoinData, PLAYER)
    if ok and type(joinData) == "table" and type(joinData.TeleportData) == "table"
        and joinData.TeleportData.vichopRole == "searcher" then
        return joinData.TeleportData
    end
    return readResumeContext() or {}
end

local teleportDataOnJoin = getJoinTeleportData()
if teleportDataOnJoin.vichopRole == "searcher" then
    runtime.previousJobId = tostring(
        teleportDataOnJoin.vichopPreviousJobId or teleportDataOnJoin.vichopFromJobId or ""
    )
    runtime.rehopCount = math.max(0, tonumber(
        teleportDataOnJoin.rehopCount or teleportDataOnJoin.vichopRehopCount or runtime.rehopCount
    ) or 0)
end

local teleportConnection = TeleportService.TeleportInitFailed:Connect(function(player, result, message)
    if player == PLAYER and runtimeIsCurrent() then
        runtime.teleportError = tostring(result) .. ": " .. tostring(message)
    end
end)

local playerTeleportConnection = PLAYER.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started and env.__VICHOP_SEARCHER_RUNTIME == runtime then
        runtime.teleportStarted = true
        runtime.active = false
    end
end)

local function runSearcher()
    local arrivedValid, arrivalReason = validateArrivedServer(teleportDataOnJoin)
    runtime.arrivalStatus = arrivalReason
    if not arrivedValid then
        runtime.rehopCount = runtime.rehopCount + 1
        print("[Vichop/Searcher] Rehopping immediately:", arrivalReason)
        task.spawn(releaseReservation, game.JobId)
        requestHop("arrival rejected: " .. arrivalReason, true)
        while runtimeIsCurrent() do
            task.wait(SCAN_INTERVAL_SECONDS)
        end
        return
    end
    serverStartedAtClock = os.clock()

    task.spawn(function()
        while runtimeIsCurrent() do
            task.wait(HEARTBEAT_SECONDS)
            if runtimeIsCurrent() and not runtime.hopping and runtime.currentReservationOwned then
                local heartbeatOk = heartbeatReservation(game.JobId)
                if not heartbeatOk then
                    runtime.currentReservationOwned = false
                    warn("[Vichop/Searcher] Lost this server reservation")
                    runtime.rehopCount = runtime.rehopCount + 1
                    requestHop("reservation lease lost", true)
                end
            end
        end
    end)

    print("[Vichop/Searcher] Running", SEARCHER_ID, "in", shortJobId(game.JobId))

    local lastVicious = nil
    while runtimeIsCurrent() do
        if not runtime.hopping then
            local monster, level = getVicious()
            if monster then
                if not lastVicious then
                    publishSpawn(monster, level)
                elseif now() - lastJobHeartbeat >= HEARTBEAT_SECONDS then
                    heartbeatJob(monster, level)
                end
            elseif lastVicious then
                print("[Vichop/Searcher] Vicious disappeared; leaving immediately")
                task.spawn(reportMissing)
                requestHop("Vicious disappeared", false)
            elseif os.clock() - serverStartedAtClock >= INITIAL_SCAN_SECONDS then
                requestHop("no live Vicious found", false)
            end
            lastVicious = monster

            if now() - lastCleanup >= CLEANUP_INTERVAL_SECONDS then
                lastCleanup = now()
                scheduleCleanup()
            end
        end
        task.wait(SCAN_INTERVAL_SECONDS)
    end
end

local function tracebackMessage(message)
    if debug and type(debug.traceback) == "function" then
        return debug.traceback(tostring(message))
    end
    return tostring(message)
end

local runOk, runError = xpcall(runSearcher, tracebackMessage)
runtime.active = false
if not runOk then
    warn("[Vichop/Searcher] Main loop stopped and can be restarted:", tostring(runError))
end

if teleportConnection then
    teleportConnection:Disconnect()
end
if playerTeleportConnection then
    playerTeleportConnection:Disconnect()
end
