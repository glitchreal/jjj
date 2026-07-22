-- Vichop searcher: reserves public servers, publishes live Vicious Bee jobs,
-- and moves on as soon as the current server is no longer useful.

local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Stats = game:GetService("Stats")
local TeleportService = game:GetService("TeleportService")

local env = type(getgenv) == "function" and getgenv() or _G
local ANTILAG_ENABLED = env.VICHOP_ANTILAG_ENABLED
if type(ANTILAG_ENABLED) ~= "boolean" then
    ANTILAG_ENABLED = true
end
local ANTILAG_MODE = type(env.VICHOP_ANTILAG_MODE) == "string"
    and string.lower(env.VICHOP_ANTILAG_MODE) or "aggressive"
if ANTILAG_MODE ~= "off" and ANTILAG_MODE ~= "safe" and ANTILAG_MODE ~= "aggressive" then
    warn("[Vichop/AntiLag] Invalid mode; falling back to safe")
    ANTILAG_MODE = "safe"
end
if not ANTILAG_ENABLED then
    ANTILAG_MODE = "off"
end
env.VICHOP_ANTILAG_ENABLED = ANTILAG_ENABLED
env.VICHOP_ANTILAG_MODE = ANTILAG_MODE

local BSS_PLACE_ID = 1537690962
local DATABASE_URL = "https://vichop-coordination-2026-default-rtdb.firebaseio.com"
local ROBLOX_SERVER_LIST_URL = "https://games.roblox.com/v1/games/" .. tostring(BSS_PLACE_ID)
    .. "/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100"
local INITIAL_SCAN_SECONDS = 5
local SCAN_INTERVAL_SECONDS = 0.25
local HEARTBEAT_SECONDS = 5
local RESERVATION_HEARTBEAT_SECONDS = 3
local RESERVATION_TTL_SECONDS = 20
local OWN_RECENT_TTL_SECONDS = 10 * 60
local FLEET_RECENT_TTL_SECONDS = 45
local JOB_STALE_SECONDS = 35
local CLEANUP_INTERVAL_SECONDS = 30
local HTTP_TIMEOUT_SECONDS = 15
local TELEPORT_TIMEOUT_SECONDS = 7
local TELEPORT_BACKOFF_MAX_SECONDS = 3
local KILLER_SLOT_RELEASE_GRACE_SECONDS = 3
local CANDIDATE_TTL_SECONDS = 3 * 60
local CANDIDATE_POOL_TARGET = 35
local CANDIDATE_POOL_MAX = 120
local CANDIDATE_RESERVATION_ATTEMPTS = 12
local REFILL_LEASE_SECONDS = 15
local REFILL_PAGES_PER_LEASE = 2
local REFILL_RETRY_SECONDS = 2
local PREPARATION_STALE_SECONDS = 45
local CHARACTER_READY_TIMEOUT_SECONDS = 30
local CHARACTER_SETTLE_SECONDS = 2
local MONSTERS_READY_TIMEOUT_SECONDS = 15
local ANTILAG_INITIAL_BATCH_SIZE = 600
local ANTILAG_ADDED_BATCH_SIZE = 100
local ANTILAG_HEALTH_HOP_INTERVAL = 10
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
local monstersDeadline = os.clock() + MONSTERS_READY_TIMEOUT_SECONDS
while not workspace:FindFirstChild("Monsters") and os.clock() < monstersDeadline do
    task.wait(0.1)
end
if not workspace:FindFirstChild("Monsters") then
    warn("[Vichop/Searcher] Workspace.Monsters was not ready before the bounded timeout")
end
local RESUME_FILE = "vichop_searcher_resume_" .. tostring(PLAYER.UserId) .. ".json"

local previousRuntime = env.__VICHOP_SEARCHER_RUNTIME
if type(previousRuntime) == "table" and previousRuntime.active and previousRuntime.jobId == game.JobId then
    print("[Vichop/Searcher] Already running in this server")
    return
end
if type(previousRuntime) == "table" and type(previousRuntime.antiLag) == "table"
    and previousRuntime.antiLag.connection then
    pcall(function()
        previousRuntime.antiLag.connection:Disconnect()
    end)
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
    currentReservationFailures = 0,
    cleanupRunning = false,
    previousJobId = "",
    expectedJobId = "",
    arrivalStatus = "pending",
    nextHop = nil,
    preparing = false,
    preparationGeneration = 0,
    preparationStartedAt = 0,
    refillRunning = false,
    backgroundRequests = 0,
    httpRequests = 0,
    stopBackground = false,
    waitingLogged = false,
    holdPosition = false,
    state = "STARTING",
    serverListRequests = 0,
    saw429 = false,
    hopRecords = {},
    hopCount = 1,
    successfulHopCount = 0,
    sameServerCount = 0,
    httpTimeoutCount = 0,
    crashCount = 0,
    emergencyRejoinActive = false,
    statusGui = nil,
    tutorialConnection = nil,
    antiLag = {
        mode = ANTILAG_MODE,
        processed = 0,
        disabled = 0,
        destroyed = 0,
        protected = 0,
        workerRunning = false,
        connection = nil,
        connectionCount = 0,
    },
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
local lastCleanup = os.time()
local serverStartedAtClock = os.clock()

local function now()
    return os.time()
end

local function hideTutorialUi(instance)
    if not instance then
        return
    end
    if (instance.Name == "Tutorial" or instance.Name == "TutorialButton") and instance:IsA("GuiObject") then
        instance.Visible = false
    end
end

local function installSearcherUi()
    local playerGui = PLAYER:FindFirstChildOfClass("PlayerGui") or PLAYER:WaitForChild("PlayerGui", 5)
    if not playerGui then
        return
    end
    for _, descendant in ipairs(playerGui:GetDescendants()) do
        hideTutorialUi(descendant)
    end
    runtime.tutorialConnection = playerGui.DescendantAdded:Connect(function(descendant)
        task.defer(hideTutorialUi, descendant)
    end)

    local old = playerGui:FindFirstChild("VichopSearcherStatus")
    if old then
        old:Destroy()
    end
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "VichopSearcherStatus"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 1000

    local label = Instance.new("TextLabel")
    label.Name = "Status"
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Position = UDim2.fromScale(0.5, 0.5)
    label.Size = UDim2.fromOffset(260, 74)
    label.BackgroundColor3 = Color3.fromRGB(255, 220, 55)
    label.BackgroundTransparency = 0.08
    label.BorderSizePixel = 0
    label.Text = "Hopping"
    label.TextColor3 = Color3.fromRGB(18, 20, 22)
    label.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
    label.TextStrokeTransparency = 0.55
    label.Font = Enum.Font.GothamBold
    label.TextSize = 32
    label.Parent = screenGui

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(18, 20, 22)
    stroke.Thickness = 3
    stroke.Parent = label

    screenGui.Parent = playerGui
    runtime.statusGui = screenGui
end

local function setSearcherStatus(status)
    local label = runtime.statusGui and runtime.statusGui:FindFirstChild("Status")
    if not label then
        return
    end
    local spawned = status == "Spawned"
    label.Text = spawned and "Spawned" or "Hopping"
    label.BackgroundColor3 = spawned and Color3.fromRGB(57, 255, 20) or Color3.fromRGB(255, 220, 55)
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

local function writeResumeContext(previousJobId, expectedJobId, prepared, requestedAt)
    if type(writefile) ~= "function" then
        warn("[Vichop/Searcher] Local resume file is unavailable; previous JobId cannot persist")
        return false
    end
    local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, {
        vichopRole = "searcher",
        vichopSearcherId = SEARCHER_ID,
        searcherId = SEARCHER_ID,
        vichopPreviousJobId = previousJobId,
        vichopFromJobId = previousJobId,
        vichopExpectedJobId = expectedJobId,
        fromJobId = previousJobId,
        expectedJobId = expectedJobId,
        candidateSource = prepared and prepared.source or nil,
        reservationResult = prepared and prepared.reservationResult or nil,
        preparedAt = prepared and prepared.reservedAt or nil,
        preparedBeforeDecision = prepared and requestedAt
            and prepared.reservedAtClock <= requestedAt or false,
        decisionToCallLatency = requestedAt and (os.clock() - requestedAt) or nil,
        serverListRequests = runtime.serverListRequests,
        saw429 = runtime.saw429,
        antiLagHopCount = runtime.hopCount,
        successfulHopCount = runtime.successfulHopCount,
        sameServerCount = runtime.sameServerCount,
        httpTimeoutCount = runtime.httpTimeoutCount,
        crashCount = runtime.crashCount,
        backgroundRequestsAtCall = runtime.backgroundRequests,
        httpRequestsAtCall = runtime.httpRequests,
        teleportedAt = now(),
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

local processedAntiLagInstances = setmetatable({}, { __mode = "k" })
local queuedAntiLagInstances = setmetatable({}, { __mode = "k" })
local antiLagQueue = {}
local antiLagQueueHead = 1
local antiLagQueueTail = 0

local destroyInAggressiveMode = {
    ParticleEmitter = true,
    Trail = true,
    Beam = true,
    Smoke = true,
    Fire = true,
    Sparkles = true,
    Sound = true,
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
    Decal = true,
    Texture = true,
    SurfaceAppearance = true,
    Highlight = true,
    SelectionBox = true,
    BloomEffect = true,
    BlurEffect = true,
    ColorCorrectionEffect = true,
    DepthOfFieldEffect = true,
    SunRaysEffect = true,
}

local disableInSafeMode = {
    ParticleEmitter = true,
    Trail = true,
    Beam = true,
    Smoke = true,
    Fire = true,
    Sparkles = true,
    PointLight = true,
    SpotLight = true,
    SurfaceLight = true,
    Highlight = true,
    BloomEffect = true,
    BlurEffect = true,
    ColorCorrectionEffect = true,
    DepthOfFieldEffect = true,
    SunRaysEffect = true,
}

local function setProperty(instance, propertyName, value)
    local readOk, current = pcall(function()
        return instance[propertyName]
    end)
    if not readOk or current == value then
        return false
    end
    return pcall(function()
        instance[propertyName] = value
    end)
end

local function isViciousRelated(instance)
    local cursor = instance
    while cursor and cursor ~= game do
        if cursor:IsA("Model") then
            local monsterType = cursor:FindFirstChild("MonsterType")
            local typeName = monsterType and tostring(monsterType.Value) or cursor.Name
            if string.find(string.lower(typeName), "vicious bee", 1, true) then
                return true
            end
        end
        cursor = cursor.Parent
    end
    return false
end

local function isProtected(instance)
    local ok, protected = pcall(function()
        if not instance or not instance.Parent then
            return true
        end
        local monsters = workspace:FindFirstChild("Monsters")
        local currentCharacter = PLAYER.Character
        local currentCamera = workspace.CurrentCamera
        if instance == workspace.Terrain or instance == monsters or instance == currentCharacter
            or instance == currentCamera then
            return true
        end
        if monsters and instance:IsDescendantOf(monsters) then
            return true
        end
        if currentCharacter and instance:IsDescendantOf(currentCharacter) then
            return true
        end
        if currentCamera and instance:IsDescendantOf(currentCamera) then
            return true
        end
        if isViciousRelated(instance) then
            return true
        end
        return not instance:IsDescendantOf(workspace)
            and not instance:IsDescendantOf(Lighting)
            and not instance:IsDescendantOf(SoundService)
    end)
    return not ok or protected
end

local function isAntiLagCandidate(instance)
    if not instance then
        return false
    end
    return destroyInAggressiveMode[instance.ClassName] == true or instance:IsA("BasePart")
end

local function optimizeInstance(instance)
    if ANTILAG_MODE == "off" or not isAntiLagCandidate(instance) or processedAntiLagInstances[instance] then
        return
    end
    processedAntiLagInstances[instance] = true
    runtime.antiLag.processed = runtime.antiLag.processed + 1

    if isProtected(instance) then
        runtime.antiLag.protected = runtime.antiLag.protected + 1
        return
    end

    if ANTILAG_MODE == "aggressive" and destroyInAggressiveMode[instance.ClassName] then
        local destroyed = pcall(function()
            instance:Destroy()
        end)
        if destroyed then
            runtime.antiLag.destroyed = runtime.antiLag.destroyed + 1
        end
        return
    end

    local changed = false
    if disableInSafeMode[instance.ClassName] then
        changed = setProperty(instance, "Enabled", false) or changed
    elseif instance:IsA("Sound") then
        changed = setProperty(instance, "Volume", 0) or changed
        pcall(function()
            instance:Stop()
        end)
    elseif instance:IsA("Decal") or instance:IsA("Texture") then
        changed = setProperty(instance, "Transparency", 1) or changed
    elseif instance:IsA("SelectionBox") then
        changed = setProperty(instance, "Visible", false) or changed
    end

    if instance:IsA("BasePart") then
        changed = setProperty(instance, "CastShadow", false) or changed
        if ANTILAG_MODE == "aggressive" then
            changed = setProperty(instance, "LocalTransparencyModifier", 1) or changed
            if instance:IsA("MeshPart") then
                changed = setProperty(instance, "RenderFidelity", Enum.RenderFidelity.Performance) or changed
            end
        end
    end

    if changed then
        runtime.antiLag.disabled = runtime.antiLag.disabled + 1
    end
end

local function applyGlobalRenderingOptimizations()
    if ANTILAG_MODE == "off" then
        return
    end
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)
    pcall(function()
        Lighting.GlobalShadows = false
    end)
    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        pcall(function()
            terrain.WaterWaveSize = 0
            terrain.WaterWaveSpeed = 0
            terrain.WaterReflectance = 0
        end)
    end
end

local function antiLagMemoryMb()
    local ok, memory = pcall(Stats.GetTotalMemoryUsageMb, Stats)
    return ok and tonumber(memory) or 0
end

local function logAntiLagHealth(force)
    if ANTILAG_MODE == "off" then
        return
    end
    if not force and runtime.hopCount % ANTILAG_HEALTH_HOP_INTERVAL ~= 0 then
        return
    end
    print(string.format(
        "[Vichop/AntiLag] mode=%s processed=%d disabled=%d destroyed=%d protected=%d memoryMB=%.1f",
        ANTILAG_MODE,
        runtime.antiLag.processed,
        runtime.antiLag.disabled,
        runtime.antiLag.destroyed,
        runtime.antiLag.protected,
        antiLagMemoryMb()
    ))
end

local startAddedAntiLagWorker
startAddedAntiLagWorker = function()
    if runtime.antiLag.workerRunning or antiLagQueueHead > antiLagQueueTail or not runtimeIsCurrent() then
        return
    end
    runtime.antiLag.workerRunning = true
    task.spawn(function()
        local processedInBatch = 0
        while runtimeIsCurrent() and antiLagQueueHead <= antiLagQueueTail do
            local instance = antiLagQueue[antiLagQueueHead]
            antiLagQueue[antiLagQueueHead] = nil
            antiLagQueueHead = antiLagQueueHead + 1
            if instance then
                queuedAntiLagInstances[instance] = nil
                optimizeInstance(instance)
            end
            processedInBatch = processedInBatch + 1
            if processedInBatch >= ANTILAG_ADDED_BATCH_SIZE then
                processedInBatch = 0
                task.wait()
            end
        end
        if antiLagQueueHead > antiLagQueueTail then
            table.clear(antiLagQueue)
            antiLagQueueHead = 1
            antiLagQueueTail = 0
        end
        runtime.antiLag.workerRunning = false
        if runtimeIsCurrent() and antiLagQueueHead <= antiLagQueueTail then
            startAddedAntiLagWorker()
        end
    end)
end

local function queueAddedAntiLagInstance(instance)
    if ANTILAG_MODE == "off" or not runtimeIsCurrent() or queuedAntiLagInstances[instance]
        or processedAntiLagInstances[instance] or not isAntiLagCandidate(instance) then
        return
    end
    local monsters = workspace:FindFirstChild("Monsters")
    if monsters and (instance == monsters or instance:IsDescendantOf(monsters)) then
        return
    end
    queuedAntiLagInstances[instance] = true
    antiLagQueueTail = antiLagQueueTail + 1
    antiLagQueue[antiLagQueueTail] = instance
    startAddedAntiLagWorker()
end

local function stopAntiLag()
    local connection = runtime.antiLag.connection
    runtime.antiLag.connection = nil
    runtime.antiLag.connectionCount = 0
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(antiLagQueue)
    antiLagQueueHead = 1
    antiLagQueueTail = 0
end

local function startAntiLag()
    if ANTILAG_MODE == "off" or runtime.antiLag.connection then
        return
    end
    applyGlobalRenderingOptimizations()
    runtime.antiLag.connection = game.DescendantAdded:Connect(queueAddedAntiLagInstance)
    runtime.antiLag.connectionCount = 1
    env.__VICHOP_ANTILAG_TELEMETRY = runtime.antiLag

    runtime.antiLag.workerRunning = true
    task.spawn(function()
        local roots = { workspace, Lighting, SoundService }
        for _, root in ipairs(roots) do
            if not runtimeIsCurrent() then
                break
            end
            local descendants = root:GetDescendants()
            for index, instance in ipairs(descendants) do
                if not runtimeIsCurrent() then
                    break
                end
                optimizeInstance(instance)
                if index % ANTILAG_INITIAL_BATCH_SIZE == 0 then
                    task.wait()
                end
            end
            table.clear(descendants)
            descendants = nil
            task.wait()
        end
        runtime.antiLag.workerRunning = false
        if runtimeIsCurrent() then
            logAntiLagHealth(runtime.hopCount == 1 or runtime.hopCount % ANTILAG_HEALTH_HOP_INTERVAL == 0)
            startAddedAntiLagWorker()
        end
    end)
end

local function beginBackgroundRequest()
    if runtime.stopBackground or not runtimeIsCurrent() then
        return false
    end
    runtime.backgroundRequests = runtime.backgroundRequests + 1
    return true
end

local function finishBackgroundRequest()
    runtime.backgroundRequests = math.max(0, runtime.backgroundRequests - 1)
end

local function runBackground(label, callback)
    if not beginBackgroundRequest() then
        return false
    end
    local ok, result = xpcall(callback, function(message)
        if debug and type(debug.traceback) == "function" then
            return debug.traceback(tostring(message))
        end
        return tostring(message)
    end)
    finishBackgroundRequest()
    if not ok then
        warn("[Vichop/Searcher] Background " .. label .. " failed:", tostring(result))
        return false
    end
    return true, result
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
    options.Timeout = options.Timeout or HTTP_TIMEOUT_SECONDS
    runtime.httpRequests = runtime.httpRequests + 1
    local ok, response = pcall(httpRequest, options)
    runtime.httpRequests = math.max(0, runtime.httpRequests - 1)
    if not ok or type(response) ~= "table" then
        runtime.httpTimeoutCount = runtime.httpTimeoutCount + 1
        warn("[Vichop/Searcher] HTTP request failed:", tostring(response))
        return nil, 0
    end
    local status = responseStatus(response)
    if status == 0 then
        runtime.httpTimeoutCount = runtime.httpTimeoutCount + 1
    end
    return response, status
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
    firebaseWrite("PUT", "/recentServers/" .. SEARCHER_ID .. "/" .. tostring(jobId) .. ".json", timestamp)
    firebaseWrite("PUT", "/fleetRecent/" .. tostring(jobId) .. ".json", {
        searcherId = SEARCHER_ID,
        checkedAt = timestamp,
        placeId = game.PlaceId,
    })
end

local function candidatePath(jobId)
    return "/candidatePool/" .. tostring(jobId) .. ".json"
end

local function stableCandidateScore(jobId)
    local value = SEARCHER_ID .. ":" .. tostring(jobId)
    local score = 5381
    for index = 1, #value do
        score = (score * 33 + string.byte(value, index)) % 2147483647
    end
    return score
end

local function candidateIsFresh(candidate, timestamp)
    return type(candidate) == "table"
        and type(candidate.jobId) == "string"
        and candidate.jobId ~= ""
        and tonumber(candidate.placeId) == game.PlaceId
        and tonumber(candidate.discoveredAt or 0) >= timestamp - CANDIDATE_TTL_SECONDS
        and tonumber(candidate.playing or 0) < tonumber(candidate.maxPlayers or 0)
end

local function acquireRefillLease()
    local timestamp = now()
    local leaseId = runtime.generation .. ":" .. tostring(timestamp)
    local acquired, reason = atomicMutate("/candidatePoolMeta/refillLease.json", function(current)
        if type(current) == "table" and tonumber(current.expiresAt or 0) > timestamp
            and current.searcherId ~= SEARCHER_ID then
            return nil, "lease_held"
        end
        return {
            searcherId = SEARCHER_ID,
            leaseId = leaseId,
            acquiredAt = timestamp,
            heartbeatAt = timestamp,
            expiresAt = timestamp + REFILL_LEASE_SECONDS,
        }, "lease_acquired"
    end, 3)
    return acquired and leaseId or nil, reason
end

local function releaseRefillLease(leaseId)
    return atomicDeleteIf("/candidatePoolMeta/refillLease.json", function(current)
        return type(current) == "table" and current.searcherId == SEARCHER_ID
            and current.leaseId == leaseId
    end)
end

local function pruneCandidatePool(pool)
    local timestamp = now()
    local entries = {}
    for jobId, candidate in pairs(type(pool) == "table" and pool or {}) do
        table.insert(entries, {
            jobId = jobId,
            stale = not candidateIsFresh(candidate, timestamp),
            discoveredAt = tonumber(type(candidate) == "table" and candidate.discoveredAt or 0) or 0,
        })
    end
    table.sort(entries, function(a, b)
        if a.stale ~= b.stale then
            return a.stale
        end
        return a.discoveredAt < b.discoveredAt
    end)

    local staleCount = 0
    for index = 1, #entries do
        if entries[index].stale then
            staleCount = staleCount + 1
        end
    end
    local removeCount = math.min(30, #entries, math.max(staleCount, #entries - CANDIDATE_POOL_MAX))
    for index = 1, removeCount do
        firebaseWrite("DELETE", candidatePath(entries[index].jobId))
        pool[entries[index].jobId] = nil
    end

    local remaining = 0
    local fresh = 0
    for _, candidate in pairs(pool) do
        remaining = remaining + 1
        if candidateIsFresh(candidate, timestamp) then
            fresh = fresh + 1
        end
    end
    return remaining, fresh
end

local function refillCandidatePool()
    if runtime.refillRunning or runtime.stopBackground or not runtimeIsCurrent() then
        return false, "refill_unavailable"
    end
    runtime.refillRunning = true

    local jitter = 0.05 + (stableCandidateScore(runtime.generation) % 300) / 1000
    task.wait(jitter)
    if runtime.stopBackground or not runtimeIsCurrent() then
        runtime.refillRunning = false
        return false, "refill_stopped"
    end

    local pool, poolReadOk = firebaseGet("/candidatePool.json")
    if not poolReadOk then
        runtime.refillRunning = false
        return false, "pool_unavailable"
    end
    pool = type(pool) == "table" and pool or {}
    local poolSize, freshCount = pruneCandidatePool(pool)
    if freshCount >= CANDIDATE_POOL_TARGET then
        runtime.refillRunning = false
        return true, "pool_ready"
    end

    local cooldownUntil = tonumber(firebaseGet("/candidatePoolMeta/cooldownUntil.json") or 0) or 0
    if cooldownUntil > now() then
        runtime.refillRunning = false
        return false, "cooldown"
    end

    local leaseId, leaseReason = acquireRefillLease()
    if not leaseId then
        runtime.refillRunning = false
        return false, leaseReason
    end

    local cursorValue = firebaseGet("/candidatePoolMeta/nextCursor.json")
    local cursor = type(cursorValue) == "string" and cursorValue ~= "" and cursorValue or nil
    local writeBudget = math.max(0, CANDIDATE_POOL_MAX - poolSize)
    local refillOk = false
    local refillReason = "empty_response"

    for _ = 1, REFILL_PAGES_PER_LEASE do
        if runtime.stopBackground or not runtimeIsCurrent() or writeBudget <= 0 then
            break
        end
        local url = ROBLOX_SERVER_LIST_URL
        if cursor then
            url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
        end
        runtime.serverListRequests = runtime.serverListRequests + 1
        local response, status = rawRequest({ Url = url, Method = "GET" })
        if status == 429 then
            runtime.saw429 = true
            local retryAfter = tonumber(responseHeader(response, "retry-after")) or 10
            firebaseWrite("PUT", "/candidatePoolMeta/cooldownUntil.json", now() + math.max(1, retryAfter))
            refillReason = "rate_limited"
            break
        end
        if status < 200 or status >= 300 then
            firebaseWrite("PUT", "/candidatePoolMeta/cooldownUntil.json", now() + REFILL_RETRY_SECONDS)
            refillReason = "server_list_" .. tostring(status)
            break
        end

        local page, decoded = decodeBody(response)
        if not decoded or type(page) ~= "table" then
            refillReason = "invalid_server_page"
            break
        end

        local writes = {}
        local writeCount = 0
        for _, server in ipairs(type(page.data) == "table" and page.data or {}) do
            local jobId = type(server.id) == "string" and server.id or ""
            if writeCount < writeBudget and jobId ~= "" and jobId ~= game.JobId
                and tonumber(server.playing or 0) < tonumber(server.maxPlayers or 0) then
                writes[jobId] = {
                    jobId = jobId,
                    placeId = game.PlaceId,
                    playing = tonumber(server.playing or 0),
                    maxPlayers = tonumber(server.maxPlayers or 0),
                    discoveredAt = now(),
                    discoveredBy = SEARCHER_ID,
                }
                writeCount = writeCount + 1
            end
        end
        if writeCount > 0 then
            firebaseWrite("PATCH", "/candidatePool.json", writes)
            writeBudget = writeBudget - writeCount
            refillOk = true
            refillReason = "refilled"
        end

        cursor = type(page.nextPageCursor) == "string" and page.nextPageCursor ~= ""
            and page.nextPageCursor or nil
        firebaseWrite("PUT", "/candidatePoolMeta/nextCursor.json", cursor or "")
        firebaseWrite("PUT", "/candidatePoolMeta/lastRefillAt.json", now())
        if not cursor then
            firebaseWrite("PUT", "/candidatePoolMeta/cooldownUntil.json", now() + 20)
            break
        end
    end

    releaseRefillLease(leaseId)
    runtime.refillRunning = false
    return refillOk, refillReason
end

local function prepareFromCandidatePool(preparationGeneration)
    local pool, poolOk = firebaseGet("/candidatePool.json")
    local ownRecent, ownRecentOk = firebaseGet("/recentServers/" .. SEARCHER_ID .. ".json")
    local fleetRecent, fleetRecentOk = firebaseGet("/fleetRecent.json")
    if not poolOk or not ownRecentOk or not fleetRecentOk then
        return false, "coordination_unavailable"
    end
    pool = type(pool) == "table" and pool or {}
    ownRecent = type(ownRecent) == "table" and ownRecent or {}
    fleetRecent = type(fleetRecent) == "table" and fleetRecent or {}

    local timestamp = now()
    local candidates = {}
    for jobId, candidate in pairs(pool) do
        local fleetRecord = fleetRecent[jobId]
        local fleetCheckedAt = type(fleetRecord) == "table" and fleetRecord.checkedAt or fleetRecord
        local ownVisitedAt = tonumber(ownRecent[jobId] or 0) or 0
        local fleetVisitedAt = tonumber(fleetCheckedAt or 0) or 0
        if candidateIsFresh(candidate, timestamp)
            and jobId ~= game.JobId
            and jobId ~= runtime.previousJobId
            and jobId ~= runtime.expectedJobId
            and ownVisitedAt < timestamp - OWN_RECENT_TTL_SECONDS
            and fleetVisitedAt < timestamp - FLEET_RECENT_TTL_SECONDS then
            table.insert(candidates, {
                jobId = jobId,
                candidate = candidate,
                score = stableCandidateScore(jobId),
                playing = tonumber(candidate.playing or 0),
            })
        end
    end
    table.sort(candidates, function(a, b)
        if a.score ~= b.score then
            return a.score < b.score
        end
        return a.playing < b.playing
    end)

    for index = 1, math.min(#candidates, CANDIDATE_RESERVATION_ATTEMPTS) do
        local selected = candidates[index]
        local reserved, reserveReason = reserveServer(selected.jobId)
        if reserved then
            if runtime.stopBackground or runtime.holdPosition or not runtimeIsCurrent()
                or runtime.preparationGeneration ~= preparationGeneration then
                releaseReservation(selected.jobId)
                return false, "preparation_superseded"
            end
            runtime.nextHop = {
                jobId = selected.jobId,
                reservedAt = timestamp,
                reservedAtClock = os.clock(),
                expiresAt = timestamp + RESERVATION_TTL_SECONDS,
                source = selected.candidate.discoveredBy == SEARCHER_ID and "local" or "firebase",
                reservationResult = reserveReason,
            }
            firebaseWrite("DELETE", candidatePath(selected.jobId))
            print("[Vichop/Searcher] Prepared", shortJobId(selected.jobId), runtime.nextHop.source)
            return true, "prepared"
        end
    end
    return false, #candidates == 0 and "pool_empty" or "reservation_race"
end

local function ensureNextHop()
    if runtime.nextHop or runtime.stopBackground or runtime.holdPosition
        or not runtimeIsCurrent() then
        return
    end
    if runtime.preparing then
        return
    end
    runtime.preparationGeneration = runtime.preparationGeneration + 1
    local preparationGeneration = runtime.preparationGeneration
    runtime.preparing = true
    runtime.preparationStartedAt = os.clock()
    task.spawn(function()
        local backgroundOk = runBackground("destination preparation", function()
            while runtimeIsCurrent() and not runtime.stopBackground and not runtime.holdPosition
                and not runtime.nextHop and runtime.preparationGeneration == preparationGeneration do
                local prepared = prepareFromCandidatePool(preparationGeneration)
                if prepared then
                    break
                end
                refillCandidatePool()
                if not runtime.nextHop and runtimeIsCurrent() and not runtime.stopBackground then
                    task.wait(REFILL_RETRY_SECONDS)
                end
            end
        end)
        if runtime.preparationGeneration == preparationGeneration then
            runtime.preparing = false
            runtime.preparationStartedAt = 0
            runtime.refillRunning = false
        end
        if not backgroundOk and runtimeIsCurrent() and not runtime.stopBackground
            and runtime.preparationGeneration == preparationGeneration then
            task.wait(REFILL_RETRY_SECONDS)
            ensureNextHop()
        end
    end)
end

local function releasePreparedDestination()
    local prepared = runtime.nextHop
    runtime.nextHop = nil
    if not prepared then
        return
    end
    task.spawn(function()
        runBackground("prepared reservation release", function()
            releaseReservation(prepared.jobId)
        end)
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
            updated.searcherDeparting = true
            updated.searcherDepartureRequestedAt = tonumber(updated.searcherDepartureRequestedAt) or timestamp
            updated.slotReadyAt = tonumber(updated.slotReadyAt) or 0
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
            searcherDeparting = true,
            searcherDepartureRequestedAt = timestamp,
            slotReadyAt = 0,
        }, "spawned"
    end)
    if ok then
        currentJobEventId = tostring(saved.eventId or eventId)
        lastJobHeartbeat = timestamp
        print("[Vichop/Searcher] Published live Vicious job", shortJobId(game.JobId), reason)
    end
    return ok
end

local function scheduleSlotRelease()
    if not currentJobEventId then
        return true
    end
    local timestamp = now()
    local ok, reason = atomicMutate(jobPath(game.JobId), function(current)
        if type(current) ~= "table" or tostring(current.eventId or "") ~= tostring(currentJobEventId) then
            return nil, "job_replaced"
        end
        if current.status ~= "spawned" and current.status ~= "claimed" and current.status ~= "resolving" then
            return nil, "terminal"
        end
        local updated = copyTable(current)
        updated.searcherDeparting = true
        updated.searcherDepartureRequestedAt = tonumber(updated.searcherDepartureRequestedAt) or timestamp
        updated.slotReleaseInitiatedAt = timestamp
        updated.slotReadyAt = timestamp + KILLER_SLOT_RELEASE_GRACE_SECONDS
        updated.updatedAt = timestamp
        return updated, "slot_release_scheduled"
    end, 3)
    if not ok then
        warn("[Vichop/Searcher] Could not schedule killer slot handoff:", tostring(reason))
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

local function teleportToPreparedServer(prepared, reason, requestedAt, attempt)
    if not prepared or prepared.jobId == game.JobId then
        return false, "prepared destination is not different"
    end
    runtime.teleportError = nil
    runtime.teleportStarted = false
    runtime.expectedJobId = prepared.jobId

    if not scheduleSlotRelease() then
        return false, "killer slot handoff update failed"
    end

    writeResumeContext(game.JobId, prepared.jobId, prepared, requestedAt)
    local callLatency = os.clock() - requestedAt
    table.insert(runtime.hopRecords, {
        previousJobId = game.JobId,
        expectedJobId = prepared.jobId,
        preparedBeforeDecision = prepared.reservedAtClock <= requestedAt,
        callLatency = callLatency,
        candidateSource = prepared.source,
        reservationResult = prepared.reservationResult,
        serverListRequests = runtime.serverListRequests,
        saw429 = runtime.saw429,
    })
    print(string.format(
        "[Vichop/Searcher] Prepared teleport call latency %.3fs | from=%s | expected=%s | source=%s | attempt=%d | reason=%s",
        callLatency,
        shortJobId(game.JobId),
        shortJobId(prepared.jobId),
        tostring(prepared.source),
        attempt,
        tostring(reason)
    ))

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, prepared.jobId, PLAYER)
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
    runtime.state = "PREPARING_TO_TELEPORT"

    local attempt = 0
    local lastError = nil
    while runtimeIsCurrent() do
        local prepared = runtime.nextHop
        if not prepared then
            runtime.stopBackground = false
            runtime.state = "WAITING_FOR_DESTINATION"
            if not runtime.waitingLogged then
                print("[Vichop/Searcher] Waiting for a guaranteed different destination")
                runtime.waitingLogged = true
            end
            ensureNextHop()
            task.wait(0.1)
        elseif prepared.jobId == game.JobId or prepared.jobId == runtime.previousJobId then
            runtime.nextHop = nil
            runtime.stopBackground = false
            task.spawn(function()
                runBackground("invalid prepared release", function()
                    releaseReservation(prepared.jobId)
                end)
            end)
            ensureNextHop()
        else
            runtime.waitingLogged = false
            runtime.stopBackground = true
            runtime.state = "DRAINING_BACKGROUND"
            while runtimeIsCurrent() and (runtime.backgroundRequests > 0 or runtime.httpRequests > 0) do
                task.wait(0.02)
            end
            if not runtimeIsCurrent() then
                return
            end
            if runtime.nextHop ~= prepared then
                runtime.stopBackground = false
            else
                attempt = attempt + 1
                runtime.state = "TELEPORTING"
                runtime.currentReservationOwned = false
                local attemptRequestedAt = attempt == 1 and requestedAt or os.clock()
                local teleported, teleportError = teleportToPreparedServer(
                    prepared,
                    reason,
                    attemptRequestedAt,
                    attempt
                )
                if teleported then
                    return
                end

                runtime.stopBackground = false
                if teleportError ~= lastError or attempt == 1 or attempt % 5 == 0 then
                    warn("[Vichop/Searcher] Explicit teleport failed; retrying:", tostring(teleportError))
                    lastError = teleportError
                end
                if attempt % 2 == 0 then
                    runtime.nextHop = nil
                    task.spawn(function()
                        runBackground("failed destination release", function()
                            releaseReservation(prepared.jobId)
                        end)
                    end)
                    ensureNextHop()
                else
                    runBackground("prepared reservation refresh", function()
                        local reserved, reserveReason = reserveServer(prepared.jobId)
                        if reserved then
                            prepared.reservedAt = now()
                            prepared.reservedAtClock = os.clock()
                            prepared.expiresAt = now() + RESERVATION_TTL_SECONDS
                            prepared.reservationResult = reserveReason
                        else
                            runtime.nextHop = nil
                        end
                    end)
                end
                local backoff = math.min(TELEPORT_BACKOFF_MAX_SECONDS, 0.5 * (2 ^ math.min(attempt - 1, 3)))
                task.wait(backoff)
            end
        end
    end
    runtime.hopping = false
    runtime.teleportControllerRunning = false
end

local function requestHop(reason)
    if runtime.hopRequested or runtime.teleportControllerRunning or not runtimeIsCurrent() then
        return
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
        and tostring(teleportContext.vichopPreviousJobId or teleportContext.vichopFromJobId
            or teleportContext.fromJobId or "") or ""
    local expectedJobId = type(teleportContext) == "table"
        and tostring(teleportContext.vichopExpectedJobId or teleportContext.expectedJobId or "") or ""
    if type(teleportContext) == "table" and teleportContext.vichopEmergencyRejoin == true
        and expectedJobId == game.JobId then
        local reserved, reserveReason = reserveServer(game.JobId)
        if not reserved then
            return false, "emergency reservation rejected: " .. tostring(reserveReason)
        end
        runtime.currentReservationOwned = true
        return true, "emergency same-server rejoin reserved"
    end
    if previousJobId ~= "" and previousJobId == game.JobId then
        return false, "explicit teleport returned the previous server"
    end
    if expectedJobId ~= "" and expectedJobId ~= game.JobId then
        return false, "arrived in a different server than the prepared destination"
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
    markVisited(game.JobId)
    return true, expectedJobId ~= "" and "expected destination reserved" or "initial server reserved"
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
    if runtime.cleanupRunning or runtime.stopBackground then
        return
    end
    runtime.cleanupRunning = true
    task.spawn(function()
        runBackground("cleanup", expireOldData)
        runtime.cleanupRunning = false
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
    runtime.hopCount = math.max(1, (tonumber(teleportDataOnJoin.antiLagHopCount) or 0) + 1)
    runtime.successfulHopCount = math.max(0, tonumber(teleportDataOnJoin.successfulHopCount) or 0)
    runtime.sameServerCount = math.max(0, tonumber(teleportDataOnJoin.sameServerCount) or 0)
    runtime.httpTimeoutCount = math.max(0, tonumber(teleportDataOnJoin.httpTimeoutCount) or 0)
    runtime.crashCount = math.max(0, tonumber(teleportDataOnJoin.crashCount) or 0)
    runtime.previousJobId = tostring(
        teleportDataOnJoin.vichopPreviousJobId or teleportDataOnJoin.vichopFromJobId
            or teleportDataOnJoin.fromJobId or ""
    )
    runtime.expectedJobId = tostring(
        teleportDataOnJoin.vichopExpectedJobId or teleportDataOnJoin.expectedJobId or ""
    )
    if runtime.previousJobId ~= "" then
        if runtime.previousJobId == game.JobId then
            runtime.sameServerCount = runtime.sameServerCount + 1
        elseif runtime.expectedJobId == game.JobId then
            runtime.successfulHopCount = runtime.successfulHopCount + 1
        end
    end
    runtime.lastArrival = {
        previousJobId = runtime.previousJobId,
        expectedJobId = runtime.expectedJobId,
        actualJobId = game.JobId,
        preparedBeforeDecision = teleportDataOnJoin.preparedBeforeDecision == true,
        callLatency = tonumber(teleportDataOnJoin.decisionToCallLatency),
        candidateSource = teleportDataOnJoin.candidateSource,
        reservationResult = teleportDataOnJoin.reservationResult,
        serverListRequests = tonumber(teleportDataOnJoin.serverListRequests or 0) or 0,
        saw429 = teleportDataOnJoin.saw429 == true,
        backgroundRequestsAtCall = tonumber(teleportDataOnJoin.backgroundRequestsAtCall or 0) or 0,
        httpRequestsAtCall = tonumber(teleportDataOnJoin.httpRequestsAtCall or 0) or 0,
    }
    print(string.format(
        "[Vichop/Searcher] Arrival from=%s expected=%s actual=%s latency=%s source=%s",
        shortJobId(runtime.previousJobId),
        shortJobId(runtime.expectedJobId),
        shortJobId(game.JobId),
        runtime.lastArrival.callLatency and string.format("%.3f", runtime.lastArrival.callLatency) or "n/a",
        tostring(runtime.lastArrival.candidateSource or "n/a")
    ))
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

local function writeEmergencyResumeContext()
    if type(writefile) ~= "function" then
        return false
    end
    local encodeOk, encoded = pcall(HttpService.JSONEncode, HttpService, {
        vichopRole = "searcher",
        vichopSearcherId = SEARCHER_ID,
        searcherId = SEARCHER_ID,
        vichopPreviousJobId = game.JobId,
        vichopFromJobId = game.JobId,
        vichopExpectedJobId = game.JobId,
        expectedJobId = game.JobId,
        vichopEmergencyRejoin = true,
        antiLagHopCount = runtime.hopCount,
        successfulHopCount = runtime.successfulHopCount,
        sameServerCount = runtime.sameServerCount,
        httpTimeoutCount = runtime.httpTimeoutCount,
        crashCount = runtime.crashCount,
        savedAt = now(),
    })
    return encodeOk and pcall(writefile, RESUME_FILE, encoded)
end

local function beginEmergencyRejoin(errorMessage)
    if runtime.emergencyRejoinActive or runtime.teleportStarted or not runtimeIsCurrent() then
        return
    end
    runtime.emergencyRejoinActive = true
    runtime.hopping = true
    runtime.stopBackground = true
    runtime.nextHop = nil
    warn("[Vichop/Searcher] Connection error detected; rejoining exact JobId:", tostring(errorMessage))
    task.spawn(function()
        local attempt = 0
        while runtimeIsCurrent() and not runtime.teleportStarted do
            attempt = attempt + 1
            writeEmergencyResumeContext()
            local teleportData = {
                vichopRole = "searcher",
                vichopSearcherId = SEARCHER_ID,
                searcherId = SEARCHER_ID,
                vichopPreviousJobId = game.JobId,
                vichopFromJobId = game.JobId,
                vichopExpectedJobId = game.JobId,
                expectedJobId = game.JobId,
                vichopEmergencyRejoin = true,
                antiLagHopCount = runtime.hopCount,
                successfulHopCount = runtime.successfulHopCount,
                sameServerCount = runtime.sameServerCount,
                httpTimeoutCount = runtime.httpTimeoutCount,
                crashCount = runtime.crashCount,
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
    if player == PLAYER and runtimeIsCurrent() then
        runtime.teleportError = tostring(result) .. ": " .. tostring(message)
    end
end)

local playerTeleportConnection = PLAYER.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started and env.__VICHOP_SEARCHER_RUNTIME == runtime then
        runtime.teleportStarted = true
        runtime.active = false
        stopAntiLag()
        if runtime.statusGui then
            runtime.statusGui:Destroy()
            runtime.statusGui = nil
        end
    end
end)

local function runSearcher()
    task.spawn(function()
        while runtimeIsCurrent() do
            task.wait(5)
            if runtimeIsCurrent() and runtime.preparing and runtime.preparationStartedAt > 0
                and os.clock() - runtime.preparationStartedAt >= PREPARATION_STALE_SECONDS then
                warn("[Vichop/Searcher] Destination preparation stalled; restarting preparation")
                runtime.preparationGeneration = runtime.preparationGeneration + 1
                runtime.preparing = false
                runtime.preparationStartedAt = 0
                runtime.refillRunning = false
                ensureNextHop()
            end
        end
    end)

    installSearcherUi()
    setSearcherStatus("Hopping")
    task.spawn(function()
        while runtimeIsCurrent() do
            local playerGui = PLAYER:FindFirstChildOfClass("PlayerGui")
            local mainGui = playerGui and playerGui:FindFirstChild("ScreenGui")
            hideTutorialUi(mainGui and mainGui:FindFirstChild("Tutorial"))
            hideTutorialUi(mainGui and mainGui:FindFirstChild("TutorialButton"))
            task.wait(0.5)
        end
    end)
    getVicious()
    startAntiLag()

    local arrivedValid, arrivalReason = validateArrivedServer(teleportDataOnJoin)
    runtime.arrivalStatus = arrivalReason
    if not arrivedValid then
        print("[Vichop/Searcher] Arrival rejected; preparing explicit destination:", arrivalReason)
        if runtime.expectedJobId ~= "" and runtime.expectedJobId ~= game.JobId then
            local abandonedJobId = runtime.expectedJobId
            task.spawn(function()
                runBackground("abandoned destination release", function()
                    releaseReservation(abandonedJobId)
                end)
            end)
        end
        ensureNextHop()
        requestHop("arrival rejected: " .. arrivalReason)
        while runtimeIsCurrent() do
            task.wait(SCAN_INTERVAL_SECONDS)
        end
        return
    end
    serverStartedAtClock = os.clock()
    runtime.state = "SCANNING"
    ensureNextHop()

    task.spawn(function()
        while runtimeIsCurrent() do
            task.wait(RESERVATION_HEARTBEAT_SECONDS)
            if runtimeIsCurrent() and not runtime.stopBackground then
                runBackground("reservation heartbeat", function()
                    if runtime.currentReservationOwned then
                        local heartbeatOk = heartbeatReservation(game.JobId)
                        if heartbeatOk then
                            runtime.currentReservationFailures = 0
                        else
                            runtime.currentReservationFailures = runtime.currentReservationFailures + 1
                        end
                        if not heartbeatOk and runtime.currentReservationFailures >= 2 then
                            runtime.currentReservationOwned = false
                            warn("[Vichop/Searcher] Lost this server reservation")
                            requestHop("current reservation lease lost")
                        elseif not heartbeatOk then
                            warn("[Vichop/Searcher] Reservation heartbeat failed; retrying before leaving")
                        end
                    end
                    local prepared = runtime.nextHop
                    if prepared then
                        local preparedOk = heartbeatReservation(prepared.jobId)
                        if preparedOk then
                            prepared.expiresAt = now() + RESERVATION_TTL_SECONDS
                        elseif runtime.nextHop == prepared then
                            runtime.nextHop = nil
                            warn("[Vichop/Searcher] Lost the prepared destination reservation")
                            ensureNextHop()
                        end
                    end
                end)
            end
        end
    end)

    print("[Vichop/Searcher] Running", SEARCHER_ID, "in", shortJobId(game.JobId))

    local lastVicious = nil
    while runtimeIsCurrent() do
        if not runtime.hopping then
            local monster, level = getVicious()
            if monster then
                setSearcherStatus("Spawned")
                if not lastVicious then
                    runtime.holdPosition = false
                    if publishSpawn(monster, level) then
                        lastVicious = monster
                        print("[Vichop/Searcher] Vicious published; hopping now to release the killer slot")
                        requestHop("Vicious published; releasing slot for killer")
                    else
                        warn("[Vichop/Searcher] Vicious publish failed; retaining server and retrying")
                    end
                elseif now() - lastJobHeartbeat >= HEARTBEAT_SECONDS then
                    heartbeatJob(monster, level)
                end
            elseif lastVicious then
                setSearcherStatus("Hopping")
                print("[Vichop/Searcher] Vicious disappeared; leaving immediately")
                runtime.holdPosition = false
                task.spawn(function()
                    runBackground("missing report", reportMissing)
                end)
                ensureNextHop()
                requestHop("Vicious disappeared")
            elseif os.clock() - serverStartedAtClock >= INITIAL_SCAN_SECONDS then
                setSearcherStatus("Hopping")
                requestHop("no live Vicious found")
            end
            if not monster then
                lastVicious = nil
            end

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
    runtime.crashCount = runtime.crashCount + 1
    warn("[Vichop/Searcher] Main loop stopped and can be restarted:", tostring(runError))
end

stopAntiLag()
if teleportConnection then
    teleportConnection:Disconnect()
end
if playerTeleportConnection then
    playerTeleportConnection:Disconnect()
end
if disconnectConnection then
    disconnectConnection:Disconnect()
end
if runtime.tutorialConnection then
    runtime.tutorialConnection:Disconnect()
end
if runtime.statusGui then
    runtime.statusGui:Destroy()
end
