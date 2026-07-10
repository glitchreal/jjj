# BSS Vicious Queue

Two-script Firebase queue for coordinating Vicious Bee servers.

- `searcher_support.lua` runs on support/searcher accounts. It watches `Workspace.Monsters` for a live Vicious Bee and posts the current `JobId` to Firebase.
- `killer_support.lua` runs on the killer account. It polls Firebase for spawned Vicious jobs, joins the server, waits until the Vicious Bee is gone, marks the job killed, and keeps polling.
- The queue stores jobs by JobId, so multiple searchers in the same server update one shared entry instead of creating duplicates.
- Searchers automatically serverhop when no Vicious Bee is found, stop hopping while one is alive, then continue hopping after it is killed.

## Loaders

Run this on each searcher/support account:

```lua
repeat wait() until game:IsLoaded() and game.Players.LocalPlayer 
loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/searcher_support.lua?t=" .. os.time()))()
```

Run this on the killer account:

```lua
repeat wait() until game:IsLoaded() and game.Players.LocalPlayer 
loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/killer_support.lua?t=" .. os.time()))()
```

For searchers, put the loader in your executor autoexecute folder so it starts again after every teleport.

## Killer Tracker And Webhook

The killer script includes a compact Vichop tracker. It shows total and current-session kills, stingers gained, joined servers, and session uptime. When the executor supports the `Drawing` API, the tracker appears in the upper-left; otherwise the same events are shown through Roblox notifications and the executor console.

Totals are saved locally as `vichop_stats.json`, so they carry on through teleports and executor restarts. Stingers are measured from the killer's `CoreStats.Stingers` value before and shortly after each confirmed Vicious kill.

To enable Discord reports without exposing the URL on GitHub, use this killer loader instead:

```lua
repeat wait() until game:IsLoaded() and game.Players.LocalPlayer
getgenv().VICHOP_WEBHOOK_URL = "PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE" 
loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/killer_support.lua?t=" .. os.time()))()
```

Every confirmed kill sends one embed with the stingers gained, session totals, lifetime totals, and a shortened server ID. Keep a webhook URL private: anyone who has it can post messages to that channel.

## Firebase

Database URL:

```txt
https://bss-job-queue-7bf75-default-rtdb.firebaseio.com
```

The database stores queue entries under `/jobs/<JobId>`.

Job statuses:

- `spawned`: searcher found a live Vicious Bee.
- `claimed`: killer is joining or has joined the server.
- `killed`: Vicious Bee is gone.
- `expired`: old job was ignored because it went stale.

## Detection

The scripts detect only live Vicious Bee monsters under:

```lua
Workspace.Monsters
```

The detector checks for a model whose `MonsterType` contains `"Vicious Bee"` and whose Humanoid health is above `0`. This avoids false positives from static objects like shops, particles, or decorative Vicious models.

## Updating

After editing a script on GitHub, use the loader with `?t=` / `os.time()` as shown above so Roblox does not load a cached raw file.
