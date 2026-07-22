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

getgenv().VICHOP_WEBHOOK_URL = "PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE"
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
getgenv().VICHOP_HIDE_KILLER_USER = true
getgenv().VICHOP_HIVE_TWEEN_SPEED = 55 -- optional; clamped to 25-90
-- Use the full retrying killer loader above after setting the webhook.
```

A searcher ID defaults to `searcher-<Roblox user id>`, which is stable across teleports and unique per account. It can be overridden before loading:

```lua
getgenv().VICHOP_SEARCHER_ID = "searcher-west-01"
-- Use the full retrying searcher loader above after setting the ID.
```

Use a distinct value for every simultaneously running searcher.

Every searcher hides Bee Swarm's `PlayerGui.ScreenGui.Tutorial` and `TutorialButton`, including attempts by the game to show them again. A compact centered dark panel displays `Hopping` while no live Vicious Bee is present and changes its status dot and accent to green with `Spawned` as soon as a living Vicious Bee is detected.

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

The searcher prepares a different destination during the five-second scan. When it detects a live Vicious Bee, it first publishes the Firebase job and immediately starts hopping to its already-prepared different server instead of occupying the Vicious server. Immediately before the teleport call it writes `slotReleaseInitiatedAt` and a three-second `slotReadyAt` grace deadline. The killer may atomically claim the job at once, but waits for that deadline before joining the exact server, preserving the claim while the searcher's player slot is released. If publishing fails, the searcher stays and retries so a live job is never discarded silently.

Its only normal hop call is:

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

The killer remains different by design: it must claim and explicitly join the exact `JobId` containing the detected Vicious Bee. A failed first join does not abandon the claim; the killer refreshes the lease and handoff state and retries that same exact `JobId` up to five times.

## Killer hive and combat movement

The killer claims a hive after its character finishes loading. It inspects `Workspace.HivePlatforms`, follows each platform's `Hive` ObjectValue to the corresponding `Workspace.Honeycombs` model, and treats a platform as available only when both `PlayerRef` and the Honeycomb's `Owner` are empty and its phase is `Idle`. The character Tweens to the nearest available platform, occupancy is checked again, and then `ReplicatedStorage.Events.ClaimHive` is fired with that Honeycomb's `HiveID`. Claim verification is bounded so a missing or contested hive cannot prevent the killer from handling a Vicious job.

After a claimed server is validated and a living Vicious Bee is confirmed, the killer creates one `AlignPosition` and one `AlignOrientation` on HumanoidRootPart. If `Workspace.Particles.Vicious` exists, activation first moves eight studs above the top of that actual part, then drops vertically to five studs below its bottom. The root therefore sweeps through the spike instead of approaching it sideways. Native `Touched` contact is preferred, with a bounds-checked executor touch fallback while overlapping and a second vertical sweep if contact is missed. It then follows the monster's HumanoidRootPart with temporary travel noclip. At combat range, the constraints and noclip are disabled and the Humanoid walks around the target at about five studs. If the Vicious Bee moves more than 14 studs away, AlignPosition travel resumes.

Pepper Patch and Mountain Top Field replace the close orbit after activation with one invisible, anchored, client-created `20 x 1 x 20` platform positioned 18 studs above the Vicious Bee. Detection uses the real bounds of `Workspace.FlowerZones.Pepper Patch` and `Workspace.FlowerZones.Mountain Top Field`. The platform follows the monster at a smoothing rate of 10, while a five-stud correction threshold and 1.5-stud settle threshold keep the unanchored character centered without continually forcing movement. The character can stand and walk on the platform. If platform creation fails, the existing ground orbit remains the fallback.

Only the platform is anchored. It is transparent, non-touching, non-queryable, and exists only in the local client, so it is not replicated to or controlled by other players. The platform is destroyed with the movement constraints when the Vicious Bee dies or disappears, the character changes, the claim is lost, teleport begins, the runtime is replaced, or the script ends. A live disposable simulation moved the platform for 241 frames: follow lag remained below 0.55 studs, horizontal character drift remained below the five-stud correction threshold, vertical error was effectively zero, the character remained unanchored, and the part was removed afterward. No live Vicious or Mondo Chick battle was run.

Live inspection found the Vicious definition at `ReplicatedStorage.MonsterTypes.Vicious Bee`, with a 4.5-stud attack radius, three-second aiming period, and four-second attack delay. A live level-six fight confirmed that attacks create paired, top-level `Workspace.Particles.Thorn` and `Workspace.Particles.WarningDisk` parts at matching horizontal positions. The Thorn is anchored, non-collidable, initially transparent, approximately `2.44 x 22.32 x 2.44`, and uses mesh `1033714`; its warning disk is anchored, non-collidable, approximately `10 x 0.4 x 10`, and supplies the five-stud visual danger radius. Cosmetic Thorn parts under `Workspace.Particles.Vicious` belong to the Bee's visual body and are explicitly excluded.

While hunting, one guarded `Workspace.DescendantAdded` listener prioritizes those exact top-level attack objects and retains combined ancestry, recent-creation, proximity, and geometry checks as a compatibility fallback. A 6.5-stud avoidance radius adds margin around the observed five-stud disk. Travel paths are deflected around tracked hazards, and combat orbit candidates are scored away from them. The exact warning-to-damage lifetime was not measured before the observed Vicious died, so hazards remain tracked for a conservative five-second window.

The movement controller disconnects its listeners, destroys its constraints and attachment, restores every modified collision value and Humanoid AutoRotate state, and stops walking when the target dies or disappears, the claim is lost, teleport starts, the runtime is replaced, or the script exits. Spike geometry and timing remain a compatibility risk after Bee Swarm updates; a captured live fight would allow the anonymous marker classifier and danger radius to be calibrated more precisely.

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

The killer tracker is a centered native Roblox panel using the repository-owned honey workspace artwork behind a dark readability tint, compact typography, and an animated green-to-black `Vichop Made By Qitch` title. The optimized artwork is downloaded once and cached with executor file APIs; clients without custom-asset support retain the dark fallback panel. Drag its header to reposition it. Its hive tween-speed slider ranges from 25 to 90 studs per second and defaults to 55; slider changes apply to the next hive approach and are saved in `vichop_stats.json` on executors with file APIs. It shows session kills and stingers, Total Kill, Total Stinger, stingers per hour, active searchers, current state, last result, and session uptime. Server ID and joined-server statistics are intentionally hidden.

Lifetime and active-session values are stored in `vichop_stats.json`. The session ID is passed in teleport data and in the per-account local resume file, so session counters do not reset on every hop. Writes use a temporary file before replacing the main file. Invalid JSON is copied to a timestamped `.corrupt-*.json` backup when file APIs are available, then clean defaults are used.

The Discord outcome keeps Reward, Inventory, Session, Total, and Fleet fields without a decorative embed image. Killer identity, server ID, search/hop time, joined-server count, and kill-server time are intentionally omitted. `Lifetime kills` and `Lifetime stingers` are presented as `Total Kill` and `Total Stinger`. `Stingers / hour` is calculated from session stingers divided by persistent session uptime. `Active searchers` counts unique `searcherId` values whose `/activeServers` heartbeat is no older than 20 seconds, so one searcher with current and prepared reservations is counted once. Webhook work starts asynchronously after the final stinger result is known. Before another teleport, the script allows an in-flight report only a short grace period so a slow webhook cannot stall hopping indefinitely.

After a killer teleport, the script does not resume normal queue polling until it can verify the expected claim in Firebase. Transient Firebase HTTP failures keep the killer in a recovery state. If Roblox routes an exact-instance teleport into a different server, the killer retries the same claimed destination up to five times before marking the job failed; it does not immediately abandon the claim and hop to another job.

Both roles listen for Roblox `GuiService` connection and kick errors. They first preserve their local resume context and repeatedly attempt to rejoin the exact current `JobId`. If exact-instance teleport cannot start, the visible Roblox `Retry` or `Rejoin` control is activated as a fallback when the executor exposes the required GUI signal capability. Rejoining the same instance cannot be guaranteed when Roblox has closed it, the account is banned from it, or the network is completely unavailable.

## Executor compatibility

- An executor HTTP request function (`request`, `http_request`, or `syn.request`) is required for Firebase coordination and background candidate discovery.
- Executor autoexecute is required for continuous hopping; `queue_on_teleport` is not used.
- The status trackers use native Roblox `ScreenGui` instances and do not require the executor Drawing API.
- Local file APIs preserve searcher resume context and provide a fallback when killer `TeleportData` is dropped. Without them, same-server comparison and killer claim resume are unavailable. Their absence also disables persistent lifetime statistics.
- The webhook is optional and disabled when `VICHOP_WEBHOOK_URL` is empty.
- Firebase atomic coordination requires response headers, including `ETag`, to be exposed by the executor request API.

The `?t=` loader query remains supported so raw GitHub responses are not reused from cache.
