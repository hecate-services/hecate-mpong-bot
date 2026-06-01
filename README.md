# hecate-mpong-bot

**Status: Phase 1 complete — the self-hosting game now lives here, and
hecate-daemon is mpong-free.** This repo is a Layer-2 service per the
[Hecate four-tier model][tier-model]. The Pong-over-mesh autonomy was
**ripped out of `hecate-daemon`** and moved here (2026-06-01): the full
self-hosting CQRS stack (CMD/PRJ/QRY, the game engine with AI paddles,
and the advertise/broadcast mesh emitters). Builds clean (`rebar3 compile`
+ `rebar3 as prod release`). The federated seat-negotiation path is
deferred to Phase 2. See `HANDOVER.md` for the full extraction map.

[tier-model]: https://codeberg.org/hecate-social/hecate-corpus/src/branch/main/philosophy/HECATE_TIER_MODEL.md

## What this service is

A realm-bound autonomous Pong player. Each running container is one
*bot* with its own realm-issued service-principal cert. Bots:

* **Host** bot-vs-bot matches on a schedule (the auto-host loop that
  used to be `auto_host_demo_loop` in the daemon).
* **Join** games hosted by other bots — discover them via the
  `mpong/game_advertised_v1` topic, request a seat, drive paddle
  input through `mpong/paddle_moved_v1`.
* **Broadcast** game state when hosting — same `mpong/state_broadcast_v1`
  wire shape the daemon emits today, so `/demo/mpong` on macula-realm
  doesn't change.

Spectators (the macula-realm `/demo/mpong` LiveView) stay where they
are. The bot only changes who's *publishing* the facts: from a
user-bound `hecate-daemon` to a realm-bound service principal.

## Why a service, not a daemon plugin

The cut criteria in the tier model (§"Cut criteria") put this firmly
on the Layer-2 side:

| Criterion | mpong-bot |
|---|---|
| Runs always-on without a logged-in user | ✓ (auto-host loop ticks regardless) |
| Multi-tenant | ✓ (a bot can serve seats for many concurrent games) |
| Maps to a workload class | ✓ (federated AI workload demo) |
| Holds shared mutable state that survives sessions | ✓ (game engine, match history) |
| Has its own external dependency | (none — pure self-contained) |

Same shape as `serve_llm → hecate-llm`: an always-on tenant that
was squatting in the per-user daemon, extracted into its own
container with its own identity and lifecycle.

## Architecture (intended)

```
hecate-mpong-bot (one container = one bot)
├── hecate_mpong_bot_service       — hecate_om_service callbacks
├── hecate_mpong_bot_sup           — service-level root supervisor
│   ├── cowboy /health on :8470    — via hecate_om_health_handler
│   └── hecate_mpong_bot_mesh_rpc  — fill-seat RPC handlers
└── apps/                          — vertical slices (extracted from
                                      hecate-daemon's guide_mpong_game_lifecycle)
    ├── run_game_engine/           — ticks, physics, AI paddles
    ├── advertise_game/            — mpong/game_advertised_v1 emitter
    ├── broadcast_game_state/      — mpong/state_broadcast_v1 emitter
    ├── auto_host_demo_loop/       — schedules new matches
    ├── mpong_lobby_seeker/        — finds open games to join
    ├── request_seat/, reserve_seat/, deny_seat/
    └── handle_paddle_input/       — mpong/paddle_moved_v1 sub + apply
```

Per the doctrine in `hecate-daemon/CLAUDE.md` (vertical-slicing,
no horizontal `services/` or `utils/`), each slice owns its own
supervisor and supervises its workers directly. The service-level
sup only owns service-wide infrastructure (HTTP listener,
RPC dispatcher).

## Status of the extraction — Phase 1 complete (2026-06-01)

The full **self-hosting** game lives here now, and `hecate-daemon` is
mpong-free. Moved + wired:

* `apps/guide_mpong_game_lifecycle/` — CMD: host/join/start/end +
  `register_champion`, the game engine (`mpong_game_engine` + `ball` /
  `collision` / `obstacles` / `ai` paddles), and the `advertise_game` /
  `broadcast_game_state` mesh emitters + the `auto_host_demo_loop`.
* `apps/project_mpong_games/` — PRJ (game + champion ETS projections).
* `apps/query_mpong_games/` — QRY (`list` / `get` / `stream` / `champion`).
* `src/hecate_mesh.erl` + `src/hecate_topics.erl` — thin service-local
  shims (publish a term over the bot's macula pool; build the
  byte-identical topics). They replace the daemon's `hecate_mesh` facade
  and `shared/hecate_topics` — NOT lifted verbatim.
* The game lifecycle is event-sourced into a service-local `mpong_store`,
  created in `hecate_mpong_bot_service:start/1` (the hecate-parksim pattern:
  `reckon_db_sup:start_store` + `evoq_store_subscription`).

**Deleted** (cruft, not moved): the `*_mpong_*` API duplicate family,
`mpong_paddle`, `poll_mpong_game`.

**Deferred → Phase 2** (the real federated seat-negotiation path; rebuild
from daemon git history, not carried over as stubs): `mpong_lobby_server` /
`mpong_lobby_seeker`, `request_seat` / `reserve_seat` / `deny_seat`,
`seek_lobby`, `listen_game_state`, `handle_paddle_input`, `eliminate_player`,
`leave_game`, `mpong_arena`, `discover_mpong_lobbies`.

**Build-verified:** `rebar3 compile` + `rebar3 as prod release` both green.
**Runtime** needs a service-principal cert from the deployed `macula-realm`
(`POST /api/v1/services/provision`) — see HANDOVER.md.

Wire protocol stays byte-identical, so the `macula-realm` `/demo/mpong`
spectator is unaffected once the bot publishes.

## Build

```bash
rebar3 compile
rebar3 as prod release      # or: rebar3 as prod tar
docker build -t ghcr.io/hecate-services/hecate-mpong-bot:dev .
```

Builds a complete self-hosting release. To actually host matches at
runtime it needs `HECATE_MPONG_AUTO_HOST=true` and a service-principal
cert for its mesh identity (see HANDOVER.md).

## Deploy (intended)

Container drops into `/etc/containers/systemd/` via the gitops
reconciler (see `hecate-gitops/`). One container per bot identity.
Multiple identities = multiple bots on the same host = genuine
multi-paddle pong-over-mesh from a single physical box.
