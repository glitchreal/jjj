-- Vichop searcher: reserves public servers, publishes live Vicious Bee jobs,
-- and moves on as soon as the current server is no longer useful.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local DATABASE_URL = "https://bss-job-queue-7bf75-default-rtdb.firebaseio.com"
local LOADER_URL = "https://raw.githubusercontent.com/glitchreal/jjj/main/searcher_support.lua"
local INITIAL_SCAN_SECONDS = 5
local SCAN_INTERVAL_SECONDS = 0.25
local HEARTBEAT_SECONDS = 5
local RESERVATION_TTL_SECONDS = 20
local OWN_RECENT_TTL_SECONDS = 10 * 60
local FLEET_RECENT_TTL_SECONDS = 45
local JOB_STALE_SECONDS = 35
local CLEANUP_INTERVAL_SECONDS = 30
local TELEPORT_TIMEOUT_SECONDS = 7
local TELEPORT_RETRIES = 3
local MAX_SERVER_PAGES = 2
local MAX_RESERVATION_ATTEMPTS = 8

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

local env = type(getgenv) == "function" and getgenv() or _G
local previousRuntime = env.__VICHOP_SEARCHER_RUNTIME
if type(previousRuntime) == "table" and previousRuntime.active and previousRuntime.jobId == game.JobId then
    print("[Vichop/Searcher] Already running in this server")
    return
end

local runtime = {
    active = true,
    jobId = game.JobId,
    hopping = false,
    teleportStarted = false,
    teleportError = nil,
    currentReservationOwned = false,
    expectedTarget = nil,
    cleanupRunning = false,
}
env.__VICHOP_SEARCHER_RUNTIME = runtime

local pendingSearcherContext = env.__VICHOP_SEARCHER_PENDING
local configuredSearcherId = env.VICHOP_SEARCHER_ID
    or (type(pendingSearcherContext) == "table" and pendingSearcherContext.vichopSearcherId)
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

local queueOnTeleport = queue_on_teleport or (syn and syn.queue_on_teleport)
local currentJobEventId = nil
local lastJobHeartbeat = 0
local lastCleanup = 0
local serverStartedAt = os.time()
local serverListBackoffUntil = 0
local serverListFailures = 0

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

local function getPublicServers()
    local results = {}
    local cursor = nil
    if os.clock() < serverListBackoffUntil then
        return results
    end
    for _ = 1, MAX_SERVER_PAGES do
        local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
            .. "/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
        if cursor and cursor ~= "" then
            url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
        end
        local response, status = rawRequest({ Url = url, Method = "GET" })
        if status < 200 or status >= 300 then
            serverListFailures = serverListFailures + 1
            local retryAfter = tonumber(responseHeader(response, "retry-after"))
            local cooldown = retryAfter or math.min(15, 2 ^ math.min(serverListFailures, 4))
            serverListBackoffUntil = os.clock() + cooldown
            warn("[Vichop/Searcher] Roblox server list failed:", status, "cooldown:", cooldown)
            break
        end
        serverListFailures = 0
        serverListBackoffUntil = 0
        local page, ok = decodeBody(response)
        if not ok or type(page) ~= "table" then
            break
        end
        for _, server in ipairs(type(page.data) == "table" and page.data or {}) do
            if type(server.id) == "string" and server.id ~= ""
                and server.id ~= game.JobId
                and tonumber(server.playing or 0) < tonumber(server.maxPlayers or 0) then
                table.insert(results, server)
            end
        end
        cursor = page.nextPageCursor
        if not cursor then
            break
        end
    end
    return results
end

local function chooseAndReserveServer(excluded)
    local activeServers, activeReadOk = firebaseGet("/activeServers.json")
    if not activeReadOk then
        return nil, "coordination_unavailable"
    end
    activeServers = activeServers or {}
    local ownRecent = firebaseGet("/recentServers/" .. SEARCHER_ID .. ".json") or {}
    local fleetRecent = firebaseGet("/fleetRecent.json") or {}
    local timestamp = now()
    local candidates = {}

    for _, server in ipairs(getPublicServers()) do
        local reservation = activeServers[server.id]
        local occupied = reservationIsFresh(reservation, timestamp) and reservation.searcherId ~= SEARCHER_ID
        if not occupied and not excluded[server.id] then
            local ownAge = timestamp - tonumber(ownRecent[server.id] or 0)
            local fleetRecord = fleetRecent[server.id]
            local fleetCheckedAt = type(fleetRecord) == "table" and fleetRecord.checkedAt or fleetRecord
            local fleetAge = timestamp - tonumber(fleetCheckedAt or 0)
            table.insert(candidates, {
                server = server,
                ownRecent = ownAge >= 0 and ownAge < OWN_RECENT_TTL_SECONDS,
                fleetRecent = fleetAge >= 0 and fleetAge < FLEET_RECENT_TTL_SECONDS,
                playing = tonumber(server.playing or 0),
                jitter = math.random(),
            })
        end
    end

    table.sort(candidates, function(a, b)
        if a.ownRecent ~= b.ownRecent then
            return not a.ownRecent
        end
        if a.fleetRecent ~= b.fleetRecent then
            return not a.fleetRecent
        end
        if a.playing ~= b.playing then
            return a.playing < b.playing
        end
        return a.jitter < b.jitter
    end)

    local limit = math.min(#candidates, MAX_RESERVATION_ATTEMPTS)
    for index = 1, limit do
        local jobId = candidates[index].server.id
        local reserved, reason = reserveServer(jobId)
        if reserved then
            return jobId, "reserved"
        end
        if reason == "occupied" or reason == "contended" then
            excluded[jobId] = true
        end
    end
    return nil, "no_candidate"
end

local function queueLoader(targetJobId)
    if type(queueOnTeleport) ~= "function" then
        return
    end
    local loader = string.format(
        'local e=(getgenv and getgenv() or _G);e.VICHOP_SEARCHER_ID=%q;e.__VICHOP_SEARCHER_PENDING={vichopRole="searcher",vichopSearcherId=%q,vichopExpectedJobId=%q,vichopFromJobId=%q,queuedAt=%d};loadstring(game:HttpGet("%s?t=" .. os.time()))()',
        SEARCHER_ID,
        SEARCHER_ID,
        tostring(targetJobId),
        game.JobId,
        now(),
        LOADER_URL
    )
    local ok, err = pcall(queueOnTeleport, loader)
    if not ok then
        warn("[Vichop/Searcher] Could not queue loader for teleport:", tostring(err))
    end
end

local function teleportData(targetJobId)
    return {
        vichopRole = "searcher",
        vichopSearcherId = SEARCHER_ID,
        vichopExpectedJobId = targetJobId,
        vichopFromJobId = game.JobId,
        vichopTeleportedAt = now(),
    }
end

local function teleportToReservedServer(targetJobId)
    runtime.expectedTarget = targetJobId
    runtime.teleportError = nil
    runtime.teleportStarted = false
    queueLoader(targetJobId)

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(
            game.PlaceId,
            targetJobId,
            PLAYER,
            nil,
            teleportData(targetJobId)
        )
    end)
    if not ok then
        return false, tostring(err)
    end

    local deadline = os.clock() + TELEPORT_TIMEOUT_SECONDS
    while runtime.active and os.clock() < deadline do
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

local function hopServer(reason)
    if runtime.hopping or not runtime.active then
        return
    end
    runtime.hopping = true
    print("[Vichop/Searcher] Hopping now:", reason)

    local excluded = { [game.JobId] = true }
    for attempt = 1, TELEPORT_RETRIES do
        if not runtime.active then
            runtime.hopping = false
            return
        end
        local targetJobId, selectionReason = chooseAndReserveServer(excluded)
        if not targetJobId then
            warn("[Vichop/Searcher] No server selected:", selectionReason)
            if selectionReason == "coordination_unavailable" then
                serverStartedAt = now() + 10
                break
            end
            task.wait(math.min(2, 0.5 * attempt))
        else
            if not runtime.active then
                releaseReservation(targetJobId)
                runtime.hopping = false
                return
            end
            if runtime.currentReservationOwned then
                releaseReservation(game.JobId)
                runtime.currentReservationOwned = false
            end
            print("[Vichop/Searcher] Teleport attempt", attempt, "to", shortJobId(targetJobId))
            local teleported, teleportError = teleportToReservedServer(targetJobId)
            if teleported then
                return
            end
            warn("[Vichop/Searcher] Teleport attempt failed:", tostring(teleportError))
            releaseReservation(targetJobId)
            excluded[targetJobId] = true
            task.wait(math.min(2, 0.5 * attempt))
        end
    end

    if not runtime.active then
        runtime.hopping = false
        return
    end
    local reclaimed = reserveServer(game.JobId)
    runtime.currentReservationOwned = reclaimed == true
    runtime.hopping = false
    serverStartedAt = now()
    warn("[Vichop/Searcher] Hop retries exhausted; resuming this server")
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
    local pending = env.__VICHOP_SEARCHER_PENDING
    env.__VICHOP_SEARCHER_PENDING = nil
    if type(pending) == "table" and pending.vichopRole == "searcher"
        and now() - tonumber(pending.queuedAt or 0) <= 60 then
        return pending
    end
    return {}
end

local teleportDataOnJoin = getJoinTeleportData()
if teleportDataOnJoin.vichopRole == "searcher"
    and teleportDataOnJoin.vichopExpectedJobId
    and tostring(teleportDataOnJoin.vichopExpectedJobId) ~= game.JobId then
    warn("[Vichop/Searcher] Roblox joined the wrong server; releasing the abandoned reservation")
    releaseReservation(tostring(teleportDataOnJoin.vichopExpectedJobId))
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

local function runSearcher()
    local reserved, reserveReason = reserveServer(game.JobId)
    runtime.currentReservationOwned = reserved
    if not reserved then
        warn("[Vichop/Searcher] Could not reserve the current server:", reserveReason)
        task.spawn(hopServer, "current server reservation unavailable")
    else
        markVisited(game.JobId)
    end

    task.spawn(function()
        while runtime.active do
            task.wait(HEARTBEAT_SECONDS)
            if runtime.active and not runtime.hopping and runtime.currentReservationOwned then
                local heartbeatOk = heartbeatReservation(game.JobId)
                if not heartbeatOk then
                    runtime.currentReservationOwned = false
                    warn("[Vichop/Searcher] Lost this server reservation")
                    task.spawn(hopServer, "reservation lease lost")
                end
            end
        end
    end)

    print("[Vichop/Searcher] Running", SEARCHER_ID, "in", shortJobId(game.JobId))

    local lastVicious = nil
    while runtime.active do
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
                task.spawn(hopServer, "Vicious disappeared")
            elseif now() - serverStartedAt >= INITIAL_SCAN_SECONDS then
                task.spawn(hopServer, "no live Vicious found")
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
