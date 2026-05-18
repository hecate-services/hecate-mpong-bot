# hecate-mpong-bot

**Status: scaffolded, no game code moved yet.** This repo is a Layer-2
service per the [Hecate four-tier model][tier-model], extracted from
the Pong-over-mesh autonomy that currently lives inside
`hecate-daemon`'s `guide_mpong_game_lifecycle/*`.

[tier-model]: https://codeberg.org/hecate-social/hecate-agents/src/branch/main/philosophy/HECATE_TIER_MODEL.md

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

## Status of the extraction

What lives in this repo today:

* `manifest.json` — service descriptor, matches `hecate-rag`'s shape
* `Containerfile` — multi-stage Erlang build, ghcr.io target
* `quadlet/hecate-mpong-bot.container` — Quadlet unit for system
  podman on infrastructure nodes
* `src/hecate_mpong_bot_service.erl` — `hecate_om_service` impl:
  `info / start / stop / health / capabilities / identity_spec`
* `src/hecate_mpong_bot_sup.erl` — root supervisor, today owns only
  the health-server child via `hecate_om`
* Empty `apps/` umbrella ready to receive the slices

What still lives in `hecate-daemon` and needs to move:

* `apps/guide_mpong_game_lifecycle/src/{auto_host_demo_loop, advertise_game,
  broadcast_game_state, run_game_engine, mpong_lobby_seeker,
  request_seat, reserve_seat, deny_seat, handle_paddle_input,
  host_mpong_game, join_mpong_game, listen_game_state,
  mpong_game_aggregate, register_champion, seek_lobby, start_mpong_game,
  end_game, eliminate_player, leave_game, open_lobby}/`

Wire protocol stays byte-identical so the migration can be done
incrementally — run one bot as a service alongside the existing
daemon-side bots, verify `/demo/mpong` sees both, then cut the
daemon-side off.

## Build (placeholder)

```bash
rebar3 as prod tar
docker build -t ghcr.io/hecate-services/hecate-mpong-bot:dev .
```

Won't produce a useful release until at least the auto-host slice
lands.

## Deploy (intended)

Container drops into `/etc/containers/systemd/` via the gitops
reconciler (see `hecate-gitops/`). One container per bot identity.
Multiple identities = multiple bots on the same host = genuine
multi-paddle pong-over-mesh from a single physical box.
