# BSS Vicious Queue

Vic Hop / Vichop coordinates Bee Swarm Simulator searcher accounts and one killer through Firebase Realtime Database.

- `searcher_support.lua` prepares and reserves a different public server while scanning, joins that exact `JobId`, watches `Workspace.Monsters`, and publishes a queue job only after it sees a live Vicious Bee with a living Humanoid.
- `killer_support.lua` atomically claims fresh jobs, joins the exact `JobId`, confirms a live Vicious Bee and its death, settles the stinger reward, and updates the local tracker.
- Searchers consume a fleet-wide Firebase candidate pool. One short-lived refill lease limits Roblox server-list discovery, while ETag reservations prevent searchers from preparing the same destination.

## Loaders

Put this loader directly in every searcher executor's autoexecute folder:

```lua
if not game:IsLoaded() then
    game.Loaded:Wait()
end

if game.PlaceId == 1537690962 then
    local url = "https://raw.githubusercontent.com/glitchreal/jjj/main/searcher_support.lua"
    local cacheFile = "vichop_searcher_source.lua"
    local retryDelay = 2

    while true do
        local started = false
        local downloaded, source = pcall(function()
            return game:HttpGet(url .. "?t=" .. os.time())
        end)
        if downloaded and type(source) == "string" then
            local compiled, chunk = pcall(loadstring, source)
            if compiled and type(chunk) == "function" then
                if type(writefile) == "function" then
                    pcall(writefile, cacheFile, source)
                end
                local ran, runError = pcall(chunk)
                if ran then
                    started = true
                else
                    warn("[Vichop/Loader] Searcher stopped:", tostring(runError))
                end
            else
                warn("[Vichop/Loader] Searcher source could not compile")
            end
        else
            warn("[Vichop/Loader] Searcher download failed:", tostring(source))
        end

        if not started and type(isfile) == "function" and type(readfile) == "function"
            and isfile(cacheFile) then
            local cachedOk, cachedSource = pcall(readfile, cacheFile)
            if cachedOk and type(cachedSource) == "string" then
                local compiled, chunk = pcall(loadstring, cachedSource)
                if compiled and type(chunk) == "function" then
                    local ran, runError = pcall(chunk)
                    if ran then
                        started = true
                    else
                        warn("[Vichop/Loader] Cached searcher stopped:", tostring(runError))
                    end
                end
            end
        end

        if started then
            break
        end
        task.wait(retryDelay)
        retryDelay = math.min(retryDelay * 2, 30)
    end
end
```

Put this loader directly in the killer executor's autoexecute folder:

```lua
if not game:IsLoaded() then
    game.Loaded:Wait()
end

if game.PlaceId == 1537690962 then
    local url = "https://raw.githubusercontent.com/glitchreal/jjj/main/killer_support.lua"
    local cacheFile = "vichop_killer_source.lua"
    local retryDelay = 2

    while true do
        local started = false
        local downloaded, source = pcall(function()
            return game:HttpGet(url .. "?t=" .. os.time())
        end)
        if downloaded and type(source) == "string" then
            local compiled, chunk = pcall(loadstring, source)
            if compiled and type(chunk) == "function" then
                if type(writefile) == "function" then
                    pcall(writefile, cacheFile, source)
                end
                local ran, runError = pcall(chunk)
                if ran then
                    started = true
                else
                    warn("[Vichop/Loader] Killer stopped:", tostring(runError))
                end
            else
                warn("[Vichop/Loader] Killer source could not compile")
            end
        else
            warn("[Vichop/Loader] Killer download failed:", tostring(source))
        end

        if not started and type(isfile) == "function" and type(readfile) == "function"
            and isfile(cacheFile) then
            local cachedOk, cachedSource = pcall(readfile, cacheFile)
            if cachedOk and type(cachedSource) == "string" then
                local compiled, chunk = pcall(loadstring, cachedSource)
                if compiled and type(chunk) == "function" then
                    local ran, runError = pcall(chunk)
                    if ran then
                        started = true
                    else
                        warn("[Vichop/Loader] Cached killer stopped:", tostring(runError))
                    end
                end
            end
        end

        if started then
            break
        end
        task.wait(retryDelay)
        retryDelay = math.min(retryDelay * 2, 30)
    end
end
```

Both loaders retry after 2, 4, 8, 16, and then at most 30 seconds instead of leaving the client idle after one failed GitHub request. After a successful download, they save a role-specific last-known-good source file. When executor file APIs are available, a later timeout can start from that cache immediately while preserving the same single autoexecute file per role. Existing executor autoexecute files must be replaced with these snippets; changing only the remotely downloaded support script cannot recover a failed initial download.

There is no second shared loader or role file. The support scripts themselves wait for the local character, Humanoid, and HumanoidRootPart, then allow a two-second settle window before starting Vichop. They do not use `queue_on_teleport`. Searcher and killer scripts save a small non-secret, per-account resume file before teleporting because some executors do not preserve Roblox `TeleportData`. A per-server runtime guard prevents accidental duplicate starts.

## Optional configuration

Configure the Discord webhook before the killer loadstring in its autoexecute file. The URL is never written to Firebase, the stats file, logs, or embeds.

```lua
getgenv().VICHOP_WEBHOOK_URL = "PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE"
-- Use the full retrying killer loader above after setting the webhook.
```

A searcher ID defaults to `searcher-<Roblox user id>`, which is stable across teleports and unique per account. It can be overridden before loading:

```lua
getgenv().VICHOP_SEARCHER_ID = "searcher-west-01"
-- Use the full retrying searcher loader above after setting the ID.
```

Use a distinct value for every simultaneously running searcher.

## Firebase data

The database URL remains:

```text
https://vichop-coordination-2026-default-rtdb.firebaseio.com
```

Data is stored under these paths:

```text
/jobs/<JobId>                         Vicious queue and kill outcome
/activeServers/<JobId>                searcher reservation and heartbeat
/recentServers/<searcherId>/<JobId>   per-searcher visit timestamp
/fleetRecent/<JobId>                  most recent fleet visit
/candidatePool/<JobId>                cached public destination metadata
/candidatePoolMeta/refillLease        fleet-wide discovery lease
/candidatePoolMeta/cooldownUntil      shared Roblox rate-limit cooldown
/candidatePoolMeta/nextCursor         next server-list page cursor
```

An active reservation contains `searcherId`, `claimedAt`, `heartbeatAt`, and `placeId`. Searchers refresh current and prepared reservations every 3 seconds; a heartbeat older than 20 seconds is abandoned and can be replaced. Per-searcher history is retained for 10 minutes, and fleet history excludes a server for 45 seconds.

Reservations and killer claims use Firebase REST ETags with `if-match`. This compare-and-swap operation prevents two clients from winning the same reservation or queue claim after reading the same old value. If an executor does not expose Firebase's `ETag` response header, the script refuses the unsafe claim instead of falling back to read-then-write.

## Searcher matchmaking

The searcher prepares a different destination during the five-second scan. Its only normal hop call is:

```lua
TeleportService:TeleportToPlaceInstance(
    game.PlaceId,
    preparedJobId,
    Players.LocalPlayer
)
```

`preparedJobId` is atomically reserved and must differ from the current and previous JobIds. Generic same-place matchmaking is disabled because it can return the same server. The Roblox public-server endpoint is used only by the background fleet refiller, never by the teleport controller.

Only one searcher may hold the refill lease. Its cursor and `Retry-After` cooldown are shared in Firebase, so other searchers consume cached candidates without hitting Roblox. Candidates expire after three minutes, full servers are rejected, consumed candidates are removed, and the pool is capped at 120 entries.

The resume file carries the previous and expected JobIds, candidate source, preparation state, and decision-to-call latency. Arrival is valid only when the actual JobId differs from the previous one and matches the expected one. Ownership is then revalidated before the server is marked visited.

At the no-Vicious decision, the controller freezes new background work and drains anything already in flight before saving the resume file and teleporting. It does not discover, sort, reserve, clean up, fetch GitHub, or release the old current reservation in that transition phase. The old reservation expires naturally. If no destination is prepared, one controller enters `WAITING_FOR_DESTINATION`, logs once, and teleports as soon as preparation finishes. It never falls back to generic matchmaking and never permanently gives up.

Destination preparation uses a generation guard and a 45-second watchdog. If a Firebase or executor transport call leaves one preparation generation stalled, the searcher retires that generation and starts a new one automatically instead of requiring the support script to be executed again.

The killer remains different by design: it must claim and explicitly join the exact `JobId` containing the detected Vicious Bee.

Job states:

- `spawned`: a searcher currently sees a live Vicious Bee.
- `claimed`: one killer session owns a short renewable claim lease.
- `resolving`: that owner confirmed death and is settling the reward.
- `killed`: death was confirmed and the final reward result was stored.
- `missing`: the Vicious Bee disappeared before a killer claimed it.
- `failed`: teleport, server validation, arrival, or death confirmation failed.
- `expired`: the searcher heartbeat or claim became stale.

Deploy the updated rules before running the new scripts:

```sh
firebase deploy --only database
```

`database.rules.json` permits the new paths and statuses and validates their basic shape. The database still has unauthenticated client writes because the existing executor clients do not authenticate; the validation rules prevent malformed records but cannot establish trusted identity. Add Firebase Authentication before using this queue outside a controlled group.

## Kill and reward confirmation

The killer will not report a kill unless it first sees a live Vicious Bee in the claimed `JobId` and then receives a Humanoid death signal or observes health at zero. A disappearance without either signal is a failed job.

While the Vicious Bee is alive, the killer refreshes its baseline from Bee Swarm's live `ClientStatCache:Get().Eggs.Stinger` value every 0.1 seconds. `CoreStats.Stingers` is retained only as a compatibility fallback because current Bee Swarm clients do not expose that value there. Once death is confirmed, the killer freezes that baseline and samples the same value every 0.4 seconds for up to 8 seconds. A positive result can settle early after three identical reads. The calculation is:

```text
stingersGained = max(0, finalStingerCount - stingerCountBeforeKill)
```

If either side cannot be read, the job, tracker result, and Discord embed use `Unknown`; lifetime and session stinger totals are not changed. Successful reports include both the gained amount and the before -> after inventory values. Every attempted after-value and the final result are logged without exposing credentials.

## Tracker and statistics

When `Drawing` is supported, the killer tracker shows session and lifetime kills and stingers, session stingers per hour, active searchers, joined servers, current state, shortened current server, last result, and session uptime. Console notifications remain available without `Drawing`.

Lifetime and active-session values are stored in `vichop_stats.json`. The session ID is passed in teleport data and in the per-account local resume file, so session counters do not reset on every hop. Writes use a temporary file before replacing the main file. Invalid JSON is copied to a timestamped `.corrupt-*.json` backup when file APIs are available, then clean defaults are used.

The Discord outcome uses inline Reward, Inventory, Session, Lifetime, Fleet, and Server fields. `Stingers / hour` is calculated from session stingers divided by persistent session uptime. `Active searchers` counts unique `searcherId` values whose `/activeServers` heartbeat is no older than 20 seconds, so one searcher with current and prepared reservations is counted once. Webhook work starts asynchronously after the final stinger result is known. Before another teleport, the script allows an in-flight report only a short grace period so a slow webhook cannot stall hopping indefinitely.

After a killer teleport, the script does not resume normal queue polling until it can verify the expected claim in Firebase. Transient Firebase HTTP failures keep the killer in a recovery state. If Roblox routes an exact-instance teleport into a different server, the killer retries the same claimed destination up to three times before marking the job failed; it does not immediately abandon the claim and hop to another job.

## Executor compatibility

- An executor HTTP request function (`request`, `http_request`, or `syn.request`) is required for Firebase coordination and background candidate discovery.
- Executor autoexecute is required for continuous hopping; `queue_on_teleport` is not used.
- `Drawing` is optional; its absence disables only the visual tracker.
- Local file APIs preserve searcher resume context and provide a fallback when killer `TeleportData` is dropped. Without them, same-server comparison and killer claim resume are unavailable. Their absence also disables persistent lifetime statistics.
- The webhook is optional and disabled when `VICHOP_WEBHOOK_URL` is empty.
- Firebase atomic coordination requires response headers, including `ETag`, to be exposed by the executor request API.

The `?t=` loader query remains supported so raw GitHub responses are not reused from cache.
