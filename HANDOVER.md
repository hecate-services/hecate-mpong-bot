# HANDOVER — hecate-mpong-bot

**Last updated:** 2026-05-18
**Last commit on `main`:** `1d1f9ad extract: auto_host_demo_loop + advertise_game + broadcast_game_state`
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
**Identity wired (2026-06-01):** `config/sys.config` now has the correct
`hecate_om` mesh config (io.macula realm tag + Leuven district `station_seeds`
+ `service_cert_path`), so the bot connects + publishes exactly like the
deployed `hecate-parksim`. The service-principal cert is minted by
`scripts/provision-service-cert.sh` against the **deployed** realm
`macula-realm` (`POST /api/v1/services/provision`) — but it is NOT required to
publish in v1 (the mesh doesn't yet verify realm membership; `hecate_om` holds
the cert for the v2 swap-in). (`hecate-realm` is the white-label variant, not
deployed.)
**Still NOT runtime-verified** — needs a boot against a reachable station
(prod-only; host00 can't QUIC the Hetzner stations), which is the next step.

**Phase 2** = build the real federated seat negotiation on this clean base.

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
