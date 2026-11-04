# aw-watcher-t3code

Read local T3 Code state and record one aggregate ActivityWatch heartbeat per host. No T3 authentication session is created. Prompts, messages, terminal output and diffs are not collected. Project names, thread titles, paths, branch names and provider/model identifiers are included in ActivityWatch events.

## Build and run

Requires Zig 0.17.x. SQLite is compiled into the binary; no system SQLite library or third-party Zig package is needed.

```sh
zig build -Doptimize=ReleaseFast
zig build test
./zig-out/bin/aw-watcher-t3code --dry-run
./zig-out/bin/aw-watcher-t3code doctor
./zig-out/bin/aw-watcher-t3code
```

Alternatively, use `nix develop` or `nix build`. The flake exposes `aw-watcher-t3code` and `default` for x86_64 Linux, aarch64 Linux and aarch64 macOS. The Linux Nix build uses musl for a fully static binary. macOS links system libraries, with SQLite linked statically.

Use `--help` for all flags. Defaults are `~/.t3/userdata`, ActivityWatch at `http://127.0.0.1:5600`, one-second heartbeats, a two-second merge window and a 60-second focus window. Durations accept `ms`, `s`, `m` and `h`. `--pulsetime` must exceed `--heartbeat-interval`.

Environment overrides: `T3CODE_DATA_DIR`, `AW_WATCHER_T3CODE_AW_URL`, `AW_WATCHER_T3CODE_HEARTBEAT_INTERVAL`, `AW_WATCHER_T3CODE_PULSETIME`, `AW_WATCHER_T3CODE_FOCUS_WINDOW`.

`--dry-run` prints one data object (or `null` when offline/inactive) and never contacts ActivityWatch. `doctor` checks the data directory, server PID, read-only schema query and ActivityWatch server info. It exits nonzero if any check fails.

## Recording semantics

Bucket: `aw-watcher-t3code_<hostname>`, type: `app.t3code.activity`. Event titles use `[<project>] <working|blocked|idle> (<supervised|autonomous|manual>)`.

Pending runtime requests take precedence over runs. `waiting` runs are blocked; queued, preparing, starting and running runs are working. Idle threads appear only as the recent focus candidate. Active agents are sorted by thread ID, and archived/deleted threads are excluded. A missing/dead T3 server suppresses stale running rows.

Focus is a heuristic based on recent thread visits and optional client-activity trace pulses. It does not prove OS foreground focus or identify which connected client is viewing a thread. Background work continues to count while the human is away; intersect with AFK/window buckets when querying human attention time.

ActivityWatch failures discard the current sample, without an offline queue. Every watcher startup gets a random delivery session; failures and sampling pauses rotate the delivery epoch so equal payloads cannot merge across an outage. Native file notifications wake the loop; bursts are debounced to the configured heartbeat interval to bound SQLite work. State changes appear on the next sample (one second by default). Periodic polling recovers missing directories.

## Read-only boundary

Connections use `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, `mode=ro&readonly_shm=1`, `PRAGMA query_only=ON` and a two-second busy timeout. A named VFS delegates to SQLite's native VFS while forcing read-only file opens and denying deletion; this also prevents SQLite's default read-write/create attempt for the WAL file. Temporary tables stay in memory. The watcher does not create or write-map the WAL shared-memory index, run checkpoints, migrate schemas or change journal mode. If SQLite needs a missing shared file, the sample is skipped until T3 creates it. `immutable=1` and lock bypasses are deliberately not used for the live database.

SQLite 3.54.1 sources are vendored from the [official autoconf archive](https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz), SHA-256 `926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e`. SQLite is public domain; see the source headers. No license has been declared for the watcher itself.

## User service

Install a stable binary before installing the service; moving/deleting that binary breaks startup.

```sh
aw-watcher-t3code service install --dry-run
aw-watcher-t3code service install
aw-watcher-t3code service status
aw-watcher-t3code service stop
aw-watcher-t3code service start
aw-watcher-t3code service restart
aw-watcher-t3code service uninstall
```

Installation saves explicit absolute paths and enables login startup. `stop` also disables login startup. Linux uses `systemctl --user`; macOS uses the GUI launchd domain and label `io.activitywatch.aw-watcher-t3code`. Existing external files, symlinks and services are not overwritten or removed. Nix/Home Manager-managed services must be managed through their original configuration.
