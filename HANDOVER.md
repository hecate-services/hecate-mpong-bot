# HANDOVER — hecate-mpong-bot

**Last updated:** 2026-06-01 (mesh-connect blocker RESOLVED + deployed; deps now from hex)
**Remote:** `codeberg.org/hecate-services/hecate-mpong-bot` (push-mirrored to GitHub via `sync_on_commit`).

This file exists so a fresh session after reboot can pick up the
mpong-bot extraction without re-reading the entire investigation log.
Keep it accurate. If you finish a row in the checklist below, tick it
and commit.

---

## ⚠️ STATUS UPDATE — 2026-06-01: PHASE 1 COMPLETE (rip + move)

The "what's missing" checklist below is **DONE** — superseded by a decisive
Phase 1 rip. The full live self-hosting CQRS stack was moved from hecate-daemon
and the daemon is now mpong-free:

- **Moved + wired:** `guide_mpong_game_lifecycle` (host/join/start/end +
  register_champion + engine `mpong_game_engine/ball/collision/obstacles/ai` +
  advertise/broadcast + auto_host), `project_mpong_games` (PRJ),
  `query_mpong_games` (QRY: list/get/stream/champion). Event-sourced into a
  service-local `mpong_store` created in `hecate_mpong_bot_service:start/1`
  (parksim pattern). Thin `hecate_mesh` + `hecate_topics` shims under `src/`
  publish the byte-identical `mpong/game_advertised_v1` + `state_broadcast_v1`.
- **Deleted (cruft):** the `*_mpong_*` API duplicate family, `mpong_paddle`,
  `poll_mpong_game`.
- **Deferred → Phase 2 (NOT moved; rebuild from daemon git history):** the
  federated seat-negotiation path — `mpong_lobby_server`/`seeker`,
  `request_seat`/`reserve_seat`/`deny_seat`, `seek_lobby`, `listen_game_state`,
  `handle_paddle_input`, `eliminate_player`, `leave_game`, `mpong_arena`,
  `discover_mpong_lobbies`.
- **Daemon rip:** the 3 mpong apps + their wiring (rebar relx, `?STORES`
  mpong_store, `?HECATE_APPS`, the `[mpong-trace]` block) removed; daemon
  compiles clean.

**Build-verified:** `rebar3 compile` + `rebar3 as prod release` both green.
**Identity wired (2026-06-01):** `config/sys.config` has the `hecate_om` mesh
config (io.macula realm tag + Leuven district `station_seeds`). The cert is
loaded-when-present but **NOT required to connect** — v1 connect/publish uses an
SDK-auto-generated ephemeral peering identity (the daemon's proven path). The
cert is held for the v2 realm-membership swap-in only.

**Runtime: canary on beam01 CONNECTS + publishes to the mesh (verified
2026-06-01).** `[advertise_game] Published ... mpong/game_advertised_v1: ok` and
`[broadcast_game_state] tick=N result=ok` stream continuously (no
`mesh_unavailable`). See the RESOLVED blocker below for the real root cause.

**Phase 2** = build the real federated seat negotiation on this clean base.

---

## ✅ RESOLVED + DEPLOYED (2026-06-01): the bot now connects + publishes

**Root cause: a bug in `hecate_om` 0.3.0 gated the mesh connect on service-cert
presence. The bot had no cert, so `attach_client/1` short-circuited and never
called `macula:connect`. The fix already existed in `hecate_om` git history but
had never been pushed to Codeberg, so the bot's `{branch,main}` dep kept pulling
the broken 0.3.0.**

The broken `hecate_om_identity:attach_client/1` (0.3.0, `bc6b66d3`):

```erlang
attach_client(undefined) ->        %% <-- bot lands HERE (no cert file)
    undefined;                     %% returns WITHOUT calling macula:connect
attach_client(_Cert) ->
    macula:connect(Seeds, #{})     %% NB: Opts=#{} — the cert is NOT passed!
```

The cert was a **spurious gate**: it is never passed to `macula:connect`
(`Opts=#{}`), only loaded + held for `service_cert/0` (v2). So requiring it to
connect kept every cert-less service dark. The bot had no cert → `load_cert()`
enoent → `Cert=undefined` → `attach_client(undefined)` → `undefined` → connect
never runs → **zero peering attempts** → `no_client` → every publish
`mesh_unavailable`.

**The "parksim is byte-identical and connects fine" reasoning was a red
herring.** The *deployed* parksim ALSO has no cert (`/etc/hecate/secrets/` empty
in its running container — verified). parksim is "live" via dist-Erlang + the
gRPC gateway federation, NOT the macula mesh — so its connect path was never
exercised. The earlier "macula 4.8.x internals / `84f78b` vs `35bfc6c8` commit"
lead was a **dead end** — connect was simply never reached. Do NOT re-chase it.

### Fix applied (verified, deployed)

The fix is `hecate_om` **0.3.1** (`c1dc348`), which was already committed locally
but unpushed:
- `attach_client/0` connects on **seeds**, not cert presence (cert decoupled).
- Connect is **deferred off the init path + retried** (`self() ! connect`,
  `?RECONNECT_MS`), fixing a boot race where hecate_om started before the macula
  SDK app was up. Re-attaches if the pool later dies (monitors it).
- Empty opts → the SDK auto-generates an ephemeral peering identity (the
  daemon's proven path). Optional `identity_key_path` env gives a stable on-disk
  keypair when set (the bot does not set it → ephemeral). Identity is for
  peering, not authorization.

Steps done:
1. Pushed `hecate_om` 0.3.1 (`c1dc348`) to **Codeberg** `origin/main` (canonical;
   the local `main` had wrongly been tracking the GitHub mirror).
2. Bumped this repo's `rebar.lock` to `c1dc348`; `rebar3 as prod release` green.
3. Rebuilt the container, `docker save | ssh beam01 docker load`, redeployed the
   `mpong-bot` canary with `docker run --network host -e HECATE_MPONG_AUTO_HOST=true`
   — **no cert mount needed.**
4. Verified: `[advertise_game] Published ... mpong/game_advertised_v1: ok` +
   `[broadcast_game_state] tick=N result=ok` stream continuously;
   `hecate_om_identity:macula_client()` returns a live pool (publish-ok is only
   possible with a connected pool). The realm consumes the byte-identical wire
   the daemon already publishes, so `/demo/mpong` sees the bot.
5. **hecate_om 0.3.1 + macula 4.8.0 published to hex; `rebar.config` flipped off
   the git pins → `{hecate_om, "~> 0.3.1"}` + `{macula, "~> 4.8"}`** (commit
   `4822fad`). hecate_om 0.3.1 was tagged `v0.3.1` (annotated, on the published
   commit `673e055`) + published with a `scripts/publish-to-hex.sh` helper; a
   dialyzer-exclude fix for the debug_info-less macula/reckon-db deps landed in
   it (`673e055`). Rebuilt container embeds `hecate_om-0.3.1` + `macula-4.8.0`
   **from hex**; redeployed `mpong-bot` on beam01 (image tag `:hexdeps`, aliased
   `:latest`) — re-verified connect + publish (`tick=425 result=ok`, zero
   `mesh_unavailable`). Old beam01 image tags (`fixed-noclient` + dangling)
   pruned.
6. **Realm-side `/demo/mpong` live arena fixed (2026-06-01) — was a STATION bug,
   not the bot.** Two issues, both resolved:
   - `MpongLive.lobby/1` 500'd (`BadBooleanError`) on advertised-but-not-yet-live
     games (mixed `&&`/`and`); fixed in `macula-realm` (`mpong_live.ex:208`,
     commit `bda8b1d`).
   - Game stuck on "Waiting for first tick": the realm received `game_advertised`
     but never `state_broadcast`. Root cause = **macula-station 4.7.x**:
     `macula_record_cbor:encode/1` had no negative-integer clause and **crashed
     (`function_clause`) while canonically re-encoding the payload to verify the
     publisher_sig** — so any pubsub EVENT with negative ints (mpong ball
     velocity / wall offsets) was silently dropped at the origin (the bot's seed
     station), publisher still got `ok`. NOT rate, NOT size, NOT integer map keys
     (those canonicalise identically across 4.7/4.8). 4.8.0 added the negative
     clause. Fixed by bumping the **macula-station fleet** `{macula, "~> 4.7.0"}`
     → `{macula, "~> 4.8"}` (`macula-station` commit `3c2561a`); CI built `:main`,
     watchtower rolled 4.8.0 across the fleet. Verified: full payload (negatives)
     now delivers, live game tick climbing, 3211 state EVENTs/60s, 0 crashes.
     See memory `[[macula_station_negative_int_pubsub_drop]]`.

### Follow-up still owed (next session, small)

- **Deps from hex (done):** `rebar.config` now uses `{hecate_om, "~> 0.3.1"}` +
  `{macula, "~> 4.8"}` — both published to hex, git pins dropped (commit
  `4822fad`). `rebar.lock` is gitignored but `COPY`d into the container build;
  a fresh build re-resolves from hex.
- **Stale comments** in `config/sys.config` (the `hecate_om` block) +
  `scripts/provision-service-cert.sh` (header) still say "v1 connect/publish does
  not require the cert" — that is now TRUE (0.3.1), so the comments are fine, but
  the `service_cert_path` line in sys.config is unused in v1; leave it for v2.
- **Gitops landing** — add the Quadlet to `hecate-social/hecate-gitops/` for a
  permanent canary node (the current canary is a manual `docker run`).
- **Daemon-side auto-host cutover** — once happy, flip `HECATE_MPONG_AUTO_HOST=false`
  on the daemons node-by-node (see "Open ops items" below).

**Four real build/config bugs were also found + fixed earlier** (all committed,
all still valid):
1. runtime base `alpine:3.20` → `3.22` (crypto NIF `EVP_MD_CTX_get_size_ex`).
2. missing `{evoq, [...]}` `reckon_evoq_adapter` config (`not_configured`).
3. `{mpong_auto_host, false}` in sys.config shadowed the OS-env override.
4. macula pinned to git tag `v4.8.0` (not a commit SHA — a clean container
   can't fetch arbitrary non-HEAD SHAs from codeberg).

**Ops note — ghcr package is PRIVATE.** `ghcr.io/hecate-services/hecate-mpong-bot`
is private and **cannot be flipped to public via API** (GitHub has no REST
endpoint for package visibility — `PATCH`/`PUT` both 404; it's a UI-only toggle
at github.com/orgs/hecate-services/packages). Until it's made public in the UI
(or the beams `docker login ghcr`), deploy via `docker save | ssh beamNN docker
load`. The canary on beam01 is **stopped** (`docker start mpong-bot` to resume).

---

## TL;DR — where we are

- The mpong-over-mesh demo at `https://macula.io/demo/mpong` works
  end-to-end *from the daemon* (paddles animate, lobby tiles show
  LIVE/WAITING/STALE/FINISHED, leaderboard tracks BOT(HOST) / HOSTED
  / DONE / TICKS). All three layered bugs are shipped:
  - `macula-station` frame_telemetry ETS race (commit `ace511b`)
  - `macula-realm` Mpong `record_state` throttle never fired
    (`:never` sentinel, commit `259f9d8`)
  - `macula-realm` LiveView coord conversion + paddle width + wall
    direction.
- The Layer-2 service `hecate-mpong-bot` is **scaffolded and partially
  extracted from hecate-daemon**. It builds clean today but cannot
  actually host a match yet — half the supporting modules still live
  in `hecate-daemon`.
- Migration plan: incremental. Wire shape is byte-identical, so once
  the bot can publish, it can run alongside the existing daemon-side
  auto-host bots on the beam cluster, then we cut the daemon side off
  per node.

---

## Repo state (what's in the tree)

```
hecate-mpong-bot/
├── manifest.json                # Layer-2 service manifest (callbacks, caps, ports)
├── Containerfile                # Erlang multi-stage → Alpine
├── quadlet/hecate-mpong-bot.container   # systemd Quadlet (gitops drops in /etc/containers/systemd/)
├── config/sys.config            # service config (env knobs)
├── rebar.config                 # deps: hecate_om + cowboy; relx includes guide_mpong_game_lifecycle
├── src/                         # service-level
│   ├── hecate_mpong_bot.app.src
│   ├── hecate_mpong_bot_app.erl
│   ├── hecate_mpong_bot_sup.erl
│   └── hecate_mpong_bot_service.erl  # hecate_om_service callbacks
└── apps/guide_mpong_game_lifecycle/src/   # extracted from daemon
    ├── guide_mpong_game_lifecycle.app.src
    ├── guide_mpong_game_lifecycle_app.erl
    ├── guide_mpong_game_lifecycle_sup.erl  # only supervises auto_host_demo_loop_sup when enabled
    ├── auto_host_demo_loop/
    │   ├── auto_host_demo_loop.erl         # env namespace retargeted to hecate_mpong_bot
    │   └── auto_host_demo_loop_sup.erl
    ├── advertise_game/advertise_game.erl   # verbatim — uses hecate_mesh, hecate_topics
    └── broadcast_game_state/broadcast_game_state.erl   # verbatim — same
```

---

## What's missing for runtime (extraction checklist)

The three extracted slices reference these modules. Until they land,
`auto_host_demo_loop:tick` crashes `undef` on first invocation and
`advertise_game:announce/1` / `broadcast_game_state:broadcast/2`
also `undef` at the `hecate_mesh:publish/2` call. The bot starts,
the sup stays up, but nothing reaches the mesh.

Source paths in **`hecate-social/hecate-daemon/`**:

| # | Daemon source | What it provides | Needed by | Status |
|---|---|---|---|---|
| 1 | `apps/shared/src/hecate_topics.erl` | Topic-string builder (pure fn) | advertise_game, broadcast_game_state | [ ] |
| 2 | `apps/hecate_mesh/src/hecate_mesh.erl` | Publisher facade over macula SDK | advertise_game, broadcast_game_state | [ ] *(or replace with direct `macula:publish/4`)* |
| 3 | `apps/guide_mpong_game_lifecycle/src/host_game/host_game_v1.erl` | `host_game_v1:new/3` evoq command builder | auto_host_demo_loop | [ ] |
| 4 | `apps/guide_mpong_game_lifecycle/src/host_game/maybe_host_game.erl` | Dispatches `host_game_v1` via evoq | auto_host_demo_loop | [ ] |
| 5 | `apps/guide_mpong_game_lifecycle/src/mpong_game_aggregate.erl` | Aggregate state + `stream_id/1` | auto_host_demo_loop | [ ] |
| 6 | `apps/guide_mpong_game_lifecycle/src/run_game_engine/run_game_engine_sup.erl` (and 7 sibling modules: `mpong_ai`, `mpong_arena`, `mpong_ball`, `mpong_collision`, `mpong_game_engine`, `mpong_obstacles`, `mpong_paddle`) | Engine: tick loop, AI paddles, physics | auto_host_demo_loop | [ ] |
| 7 | `apps/guide_mpong_game_lifecycle/src/join_game/join_game_v1.erl` | `join_game` evoq command | auto_host_demo_loop:dispatch_join | [ ] |
| 8 | `apps/guide_mpong_game_lifecycle/src/start_game/start_game_v1.erl` | `start_game` evoq command | auto_host_demo_loop:dispatch_start | [ ] |

Items 3–8 drag in **reckon_db / evoq / reckon_evoq / reckon_gater** as
deps. The `rebar.config` has the lines commented out — uncomment when
host_mpong_game lands:

```erlang
{reckon_db,    "1.6.3"},
{evoq,         "1.13.1"},
{reckon_evoq,  "1.5.1"},
{reckon_gater, "1.3.1"},
{esqlite,      "0.8.8"}
```

### Suggested extraction order

Two sensible passes after reboot, each one self-contained:

**Pass A — publishers fire (small, reckon-free).** Items 1 + 2. After
this `advertise_game` + `broadcast_game_state` actually publish on
the mesh. Easy verification: stand the bot up, watch a peer station
receive `mpong/game_advertised_v1` on the topic. Auto-host still
crashes on `host_one_match` because items 3–8 are absent, but the
publish surface works in isolation and can be unit-tested.

  - For item 2 the cleanest move is **not** to lift `hecate_mesh.erl`
    out of the daemon (it has shim layers, fallbacks, daemon-local
    state). Write a thin service-local replacement under
    `apps/guide_mpong_game_lifecycle/src/` or a new
    `apps/hecate_mpong_bot_mesh/`. ~30 LOC: `publish(Topic, Payload) ->
    macula:publish(default_realm(), Topic, Payload, #{}).`
    The daemon's `hecate_mesh` does pool routing + structured logging;
    a service bot doesn't need either initially.

**Pass B — auto-host fires (bigger, brings evoq).** Items 3–8. After
this a bot container is functionally equivalent to the daemon-side
auto-host bot. Drop one on a beam node alongside the daemon, watch
two lobby tiles appear in `/demo/mpong`. Then cut the daemon's
`mpong_auto_host` off node-by-node.

---

## One semantic change that's already in (don't redo)

`auto_host_demo_loop.erl:208` — `env_int/2` reads
`application:get_env(hecate_mpong_bot, Key, Default)`, **not**
`hecate`. The OS env name `HECATE_MPONG_AUTO_HOST` is preserved for
operator continuity. The `sys.config` knobs the service exposes
should be under the `hecate_mpong_bot` app key.

The env keys in use:

| Key | Default | Meaning |
|---|---|---|
| `mpong_auto_host` | `undefined` (false) | Master enable |
| `mpong_auto_host_interval_ms` | 90_000 | Match spacing |
| `mpong_auto_host_announce_ms` | 10_000 | Re-announce heartbeat |
| `mpong_auto_host_boot_delay_ms` | 15_000 | Quiet pause before first tick |
| `mpong_auto_host_bot_count` | 2 | Bots per match |

---

## Mesh wire — byte-identical to daemon

The bot publishes the same two topics as the daemon. **Do not change
the wire shape** without coordinated changes in `macula-realm`'s
`Mpong` sink and the LiveView coord conversion.

- `mpong/game_advertised_v1` — published by `advertise_game:announce/1`
- `mpong/state_broadcast_v1`  — published by `broadcast_game_state:broadcast/2`

The CBOR payload (int-keyed map, negative ints OK) is built by the
slices verbatim from the daemon source. **Macula wire rule still
applies**: pass the term, never pre-JSON-encode — the SDK encodes
CBOR. Pre-encoding crashes `macula_frame:to_wire` and crash-loops
peering. See feedback memory `feedback_macula_publish_takes_terms`.

---

## What the bot is supposed to look like (deployment)

- One container = one bot identity.
- Service-principal cert issued by the **deployed** realm `macula-realm`
  (macula.io) at install time (not derived from a human user), via its
  existing `POST /api/v1/services/provision` endpoint.
- Quadlet drops into `/etc/containers/systemd/` via the gitops
  reconciler (`hecate-social/hecate-gitops/`).
- Health on `:8470` (loopback inside the container).
- Always-on. Multi-tenant within one realm. Per the tier model
  this is firmly Layer 2 (same shape as `hecate-llm`).

---

## Open ops items (cross-repo)

These aren't in this repo but block the bot's first prod run:

1. **Cert wiring — DONE (2026-06-01).** `hecate_om_identity` already loads the
   service-principal cert (`/etc/hecate/secrets/service-cert.pem`) and connects
   the macula pool; it does NOT require the cert to connect/publish in v1 (the
   mesh doesn't yet verify realm membership — the cert is held for the v2
   swap-in). The bot-side wiring is now in place:
   - `config/sys.config` `hecate_om` section: the io.macula realm **tag**
     (64-hex), the Leuven district `station_seeds` (parksim's proven set), and
     `service_cert_path`. (The previous config was broken — missing realm tag +
     seeds, so it could never connect.)
   - `scripts/provision-service-cert.sh` mints the cert at deploy time:
     generate an Ed25519 keypair locally, POST the public key (+ the host
     node's refresh token) to `macula-realm`'s `POST /api/v1/services/provision`
     (`ServicePrincipalIssuanceController`), write the returned `service-cert.pem`
     to `/etc/hecate/secrets/hecate-mpong-bot/`. Mount it ro at
     `/etc/hecate/secrets/service-cert.pem` in the container.
   Deploy on an infra node that already holds its node-cert + refresh token.
2. **Gitops landing** — once the bot can publish, add the Quadlet to
   `hecate-social/hecate-gitops/` for one canary beam node.
3. **Daemon-side auto-host cutover** — when the bot is verified on
   one node, switch `HECATE_MPONG_AUTO_HOST=false` on that node's
   daemon, leave it on for the others, observe `/demo/mpong` showing
   exactly one bot from the new service + N-1 bots from the daemons.
   Then roll the cutover across the cluster.

---

## Build & test (today)

```bash
cd ~/work/codeberg.org/hecate-services/hecate-mpong-bot
rebar3 compile          # green
rebar3 as prod tar      # builds, but the release is a near-no-op until pass A lands
```

There are no tests yet. After pass A: stand up a single bot against a
local station, watch a macula-e2e-style probe receive
`mpong/game_advertised_v1`. After pass B: same probe should also
receive `mpong/state_broadcast_v1` at ~30 Hz for the duration of an
auto-hosted match.

---

## What NOT to do (lessons preserved)

- **Don't lift `hecate_mesh.erl` verbatim.** Write a thin service-local
  publisher. The daemon's facade has dependencies you don't want.
- **Don't pre-encode CBOR/JSON before `macula:publish/4`.** Pass the
  term. (See `feedback_macula_publish_takes_terms` memory.)
- **Don't centralise** `services/`, `utils/`, `helpers/` directories
  inside this repo. Each slice owns its sup, listeners, projections.
  Cross-domain calls go via Process Managers, never direct dispatch.
- **Don't delete features** while extracting. The daemon-side
  `guide_mpong_game_lifecycle` stays alive throughout the migration;
  this repo is additive.
- **Don't push to GitHub directly.** Codeberg is canonical, push-mirror
  replicates within seconds.

---

## Resuming after reboot — first three commands

```bash
cd ~/work/codeberg.org/hecate-services/hecate-mpong-bot
git pull --ff-only
cat HANDOVER.md   # this file — confirm checklist state
```

Then pick pass A or pass B from the extraction checklist above.
