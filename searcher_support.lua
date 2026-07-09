-- Searcher side: publishes this server's JobId when Vicious Bee is detected.
-- Paste into your executor on searcher accounts.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local DATABASE_URL = "https://bss-job-queue-7bf75-default-rtdb.firebaseio.com"
local POLL_SECONDS = 2
local SOURCE_NAME = Players.LocalPlayer and Players.LocalPlayer.Name or "searcher"

local httpRequest = request or http_request or (syn and syn.request)
assert(type(httpRequest) == "function", "No executor HTTP request function found")

local activeFirebaseKey = nil
local lastSeen = false

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

local function postSpawned(fullName)
    local timestamp = now()
    local result = firebase("POST", "/jobs.json", {
        placeId = game.PlaceId,
        jobId = game.JobId,
        status = "spawned",
        createdAt = timestamp,
        updatedAt = timestamp,
        source = SOURCE_NAME,
        note = fullName or "Vicious Bee detected",
    })

    if result and result.name then
        activeFirebaseKey = result.name
        print("Posted Vicious JobId:", game.JobId, "firebaseKey:", activeFirebaseKey)
    end
end

local function markKilled()
    if not activeFirebaseKey then
        return
    end

    firebase("PATCH", "/jobs/" .. activeFirebaseKey .. ".json", {
        status = "killed",
        updatedAt = now(),
    })

    print("Marked Vicious killed:", activeFirebaseKey)
    activeFirebaseKey = nil
end

print("Searcher support running for JobId:", game.JobId)

while task.wait(POLL_SECONDS) do
    local exists, fullName = viciousExists()

    if exists and not lastSeen then
        postSpawned(fullName)
    elseif not exists and lastSeen then
        markKilled()
    elseif exists and activeFirebaseKey then
        firebase("PATCH", "/jobs/" .. activeFirebaseKey .. ".json", {
            updatedAt = now(),
        })
    end

    lastSeen = exists
end
