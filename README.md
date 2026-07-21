# BSS Vicious Queue

Vic Hop / Vichop coordinates Bee Swarm Simulator searcher accounts and one killer through Firebase Realtime Database.

- `searcher_support.lua` uses normal Roblox public matchmaking, validates and reserves the arrived server, watches `Workspace.Monsters`, and publishes a queue job only after it sees a live Vicious Bee with a living Humanoid.
- `killer_support.lua` atomically claims fresh jobs, joins the exact `JobId`, confirms a live Vicious Bee and its death, settles the stinger reward, and updates the local tracker.
- Searchers never request or select destination `JobId` values. Active reservations, per-searcher history, and fleet history resolve matchmaking collisions after arrival and reduce short server cycles.

## Loaders

Put this loader directly in every searcher executor's autoexecute folder:

```lua
if not game:IsLoaded() then game.Loaded:Wait() end
if game.PlaceId == 1537690962 then
    loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/searcher_support.lua?t=" .. os.time()))()
end
```

Put this loader directly in the killer executor's autoexecute folder:

```lua
if not game:IsLoaded() then game.Loaded:Wait() end
if game.PlaceId == 1537690962 then
    loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/killer_support.lua?t=" .. os.time()))()
end
```

There is no second shared loader or role file. The support scripts themselves wait for the local character, Humanoid, and HumanoidRootPart, then allow a two-second settle window before starting Vichop. They do not use `queue_on_teleport`. Searcher and killer scripts save a small non-secret, per-account resume file before teleporting because some executors do not preserve Roblox `TeleportData`. A per-server runtime guard prevents accidental duplicate starts.

For the currently tested searcher account, the Opiumware loader is `/Users/andy/Opiumware/autoexec/vichop-searcher.lua`.

## Optional configuration

Configure the Discord webhook before the killer loadstring in its autoexecute file. The URL is never written to Firebase, the stats file, logs, or embeds.

```lua
getgenv().VICHOP_WEBHOOK_URL = "PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE"
if not game:IsLoaded() then game.Loaded:Wait() end
if game.PlaceId == 1537690962 then
    loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/killer_support.lua?t=" .. os.time()))()
end
```

A searcher ID defaults to `searcher-<Roblox user id>`, which is stable across teleports and unique per account. It can be overridden before loading:

```lua
getgenv().VICHOP_SEARCHER_ID = "searcher-west-01"
if not game:IsLoaded() then game.Loaded:Wait() end
if game.PlaceId == 1537690962 then
    loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/searcher_support.lua?t=" .. os.time()))()
end
```

Use a distinct value for every simultaneously running searcher.

## Firebase data

The database URL remains:

```text
https://bss-job-queue-7bf75-default-rtdb.firebaseio.com
```

Data is stored under these paths:

```text
/jobs/<JobId>                         Vicious queue and kill outcome
/activeServers/<JobId>                searcher reservation and heartbeat
/recentServers/<searcherId>/<JobId>   per-searcher visit timestamp
/fleetRecent/<JobId>                  most recent fleet visit
```

An active reservation contains `searcherId`, `claimedAt`, `heartbeatAt`, and `placeId`. Searchers refresh it every 5 seconds; a heartbeat older than 20 seconds is abandoned and can be replaced. Per-searcher history is retained for 10 minutes, and fleet history receives a strong selection penalty for 45 seconds.

Reservations and killer claims use Firebase REST ETags with `if-match`. This compare-and-swap operation prevents two clients from winning the same reservation or queue claim after reading the same old value. If an executor does not expose Firebase's `ETag` response header, the script refuses the unsafe claim instead of falling back to read-then-write.

## Searcher matchmaking

The default and only searcher hop path calls:

```lua
TeleportService:Teleport(game.PlaceId, Players.LocalPlayer, teleportData)
```

No destination `ServerInstanceId` is supplied, so Roblox public matchmaking selects the server. Searchers do not call the Roblox public-server REST endpoint and do not use candidate pools, page cursors, proxies, cookies, or rate-limit workarounds. A `429` from server-list discovery therefore cannot block normal searcher hopping.

The local resume file and `teleportData` carry the previous `JobId`, stable searcher ID, and repeated-rehop count. After arrival, the script rejects the server immediately when matchmaking returned the previous `JobId`, the account or fleet checked it recently, Firebase history is unavailable, or another active searcher wins its ETag reservation. Only a valid reservation starts the normal five-second Vicious scan and heartbeat.

The no-Vicious critical path saves the resume context locally and calls generic matchmaking immediately. The console reports precise decision-to-teleport-call latency. Teleport initialization failures use one persistent controller with capped short backoff; it never gives up after a fixed retry count. A small randomized delay applies only after three consecutive invalid arrivals, reducing repeated matchmaking collisions without slowing normal hops.

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

While the Vicious Bee is alive, the killer refreshes its baseline from the local player's live `CoreStats.Stingers` value every 0.1 seconds. Once death is confirmed, it freezes that baseline and samples the same value every 0.4 seconds for up to 8 seconds. A positive result can settle early after three identical reads. The calculation is:

```text
stingersGained = max(0, finalStingerCount - stingerCountBeforeKill)
```

If either side cannot be read, the job, tracker result, and Discord embed use `Unknown`; lifetime and session stinger totals are not changed. Every attempted after-value and the final result are logged without exposing credentials.

## Tracker and statistics

When `Drawing` is supported, the killer tracker shows session and lifetime kills and stingers, joined servers, current state, shortened current server, last result, and session uptime. Console notifications remain available without `Drawing`.

Lifetime and active-session values are stored in `vichop_stats.json`. The session ID is passed in teleport data and in the per-account local resume file, so session counters do not reset on every hop. Writes use a temporary file before replacing the main file. Invalid JSON is copied to a timestamped `.corrupt-*.json` backup when file APIs are available, then clean defaults are used.

The Discord outcome uses inline Reward, Session, Lifetime, and Server fields. Webhook work starts asynchronously after the final stinger result is known. Before another teleport, the script allows an in-flight report only a short grace period so a slow webhook cannot stall hopping indefinitely.

## Executor compatibility

- An executor HTTP request function (`request`, `http_request`, or `syn.request`) is required for Firebase coordination. Searcher matchmaking itself does not use HTTP discovery.
- Executor autoexecute is required for continuous hopping; `queue_on_teleport` is not used.
- `Drawing` is optional; its absence disables only the visual tracker.
- Local file APIs preserve resume context when the executor drops `TeleportData`; without both mechanisms, same-server comparison and killer claim resume are unavailable. Their absence also disables persistent lifetime statistics.
- The webhook is optional and disabled when `VICHOP_WEBHOOK_URL` is empty.
- Firebase atomic coordination requires response headers, including `ETag`, to be exposed by the executor request API.

The `?t=` loader query remains supported so raw GitHub responses are not reused from cache.
