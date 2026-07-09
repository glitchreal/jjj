-- Killer side: polls Firebase for spawned Vicious Bee servers, joins one,
-- waits until Vicious disappears, marks it killed, then continues polling.
-- Paste into your executor on the killer account.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local DATABASE_URL = "https://bss-job-queue-7bf75-default-rtdb.firebaseio.com"
local SCRIPT_PATH = "/scripts/killer.json"
local POLL_SECONDS = 4
local AFTER_JOIN_SETTLE_SECONDS = 8
local KILL_CHECK_SECONDS = 2
local STALE_AFTER_SECONDS = 240
local KILLER_NAME = Players.LocalPlayer and Players.LocalPlayer.Name or "killer"

local httpRequest = request or http_request or (syn and syn.request)
assert(type(httpRequest) == "function", "No executor HTTP request function found")

local function now()
    return os.time()
end

local function firebase(method, path, body)
    local response = httpRequest({
        Url = DATABASE_URL .. path,
        Method = method,
        Headers = {
            ["Content-Type"] = "application/json",
        },
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
                and (not humanoid or humanoid.Health > 0)
            then
                return true, monster:GetFullName()
            end
        end
    end

    return false, nil
end

local function getOldestSpawnedJob()
    local data = firebase(
        "GET",
        '/jobs.json?orderBy="status"&equalTo="spawned"&limitToFirst=20'
    )

    local bestKey = nil
    local bestJob = nil

    for key, job in pairs(data or {}) do
        local age = now() - tonumber(job.updatedAt or job.createdAt or 0)
        local sameServer = job.jobId == game.JobId
        local validPlace = tonumber(job.placeId) == game.PlaceId

        if validPlace and not sameServer and age <= STALE_AFTER_SECONDS then
            if not bestJob or tonumber(job.createdAt or 0) < tonumber(bestJob.createdAt or 0) then
                bestKey = key
                bestJob = job
            end
        elseif age > STALE_AFTER_SECONDS then
            firebase("PATCH", "/jobs/" .. key .. ".json", {
                status = "expired",
                updatedAt = now(),
            })
        end
    end

    return bestKey, bestJob
end

local function markJob(key, status, extra)
    local payload = extra or {}
    payload.status = status
    payload.updatedAt = now()
    firebase("PATCH", "/jobs/" .. key .. ".json", payload)
end

local function queueAfterTeleport(jobKey)
    if typeof(queue_on_teleport) ~= "function" then
        warn("queue_on_teleport is not available; re-run killer_support.lua after teleport")
        return
    end

    local code = string.format([[
        local HttpService = game:GetService("HttpService")
        local DATABASE_URL = %q
        local JOB_KEY = %q
        local SCRIPT_PATH = %q
        local httpRequest = request or http_request or (syn and syn.request)

        if type(getgenv) == "function" then
            getgenv().BSS_KILLER_ACTIVE_JOB = JOB_KEY
        end

        task.wait(1)
        local response = httpRequest({
            Url = DATABASE_URL .. SCRIPT_PATH,
            Method = "GET",
            Headers = { ["Content-Type"] = "application/json" },
        })

        local source = HttpService:JSONDecode(response.Body or response.body or "null")
        if type(source) ~= "string" then
            warn("Could not reload killer script from Firebase")
            return
        end

        loadstring(source)()
    ]], DATABASE_URL, jobKey, SCRIPT_PATH)

    queue_on_teleport(code)
end

print("Killer support running from JobId:", game.JobId)

local activeJobKey = type(getgenv) == "function" and getgenv().BSS_KILLER_ACTIVE_JOB or nil
if activeJobKey then
    print("Resumed killer support for firebaseKey:", activeJobKey)
    markJob(activeJobKey, "claimed", {
        killer = KILLER_NAME,
        joinedJobId = game.JobId,
    })

    task.wait(AFTER_JOIN_SETTLE_SECONDS)

    while task.wait(KILL_CHECK_SECONDS) do
        local exists = viciousExists()
        if not exists then
            markJob(activeJobKey, "killed", {
                killer = KILLER_NAME,
                killedInJobId = game.JobId,
            })

            if type(getgenv) == "function" then
                getgenv().BSS_KILLER_ACTIVE_JOB = nil
            end

            print("Marked Vicious killed for job:", activeJobKey)
            break
        end
    end
end

while task.wait(POLL_SECONDS) do
    local key, job = getOldestSpawnedJob()

    if key and job then
        print("Claiming Vicious JobId:", job.jobId, "firebaseKey:", key)
        markJob(key, "claimed", {
            killer = KILLER_NAME,
            claimedAt = now(),
        })

        queueAfterTeleport(key)
        task.wait(1)

        TeleportService:TeleportToPlaceInstance(tonumber(job.placeId), tostring(job.jobId), Players.LocalPlayer)
        break
    else
        print("No spawned Vicious jobs found; polling...")
    end
end
