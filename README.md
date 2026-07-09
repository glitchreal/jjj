# BSS Vicious Queue

Two-script Firebase queue for coordinating Vicious Bee servers.

- `searcher_support.lua` runs on support/searcher accounts. It watches `Workspace.Monsters` for a live Vicious Bee and posts the current `JobId` to Firebase.
- `killer_support.lua` runs on the killer account. It polls Firebase for spawned Vicious jobs, joins the server, waits until the Vicious Bee is gone, marks the job killed, and keeps polling.

## Loaders

Run this on each searcher/support account:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/searcher_support.lua?t=" .. os.time()))()
```

Run this on the killer account:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/glitchreal/jjj/main/killer_support.lua?t=" .. os.time()))()
```

## Firebase

Database URL:

```txt
https://bss-job-queue-7bf75-default-rtdb.firebaseio.com
```

The database stores queue entries under `/jobs`.

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
