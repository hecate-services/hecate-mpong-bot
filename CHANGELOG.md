# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Scaffolded
- Repo created from the `hecate-rag` template, mirroring the Layer-2
  service shape per `HECATE_TIER_MODEL.md`.
- `hecate_om_service` callbacks wired:
  `info / start / stop / health / capabilities / identity_spec`.
- Service-level supervisor with the `/health` Cowboy listener
  (port 8470) via `hecate_om_health_handler`.
- Containerfile + Quadlet unit ready for the gitops reconciler.

### Extracted from hecate-daemon (first pass)
- `apps/guide_mpong_game_lifecycle/src/auto_host_demo_loop/` — gen_server
  + sup, the autonomous match scheduler. Retargeted
  `application:get_env(hecate, …)` to
  `application:get_env(hecate_mpong_bot, …)` so the service's
  `sys.config` knobs apply.
- `apps/guide_mpong_game_lifecycle/src/advertise_game/` — pure publisher
  for `mpong/game_advertised_v1`. Verbatim.
- `apps/guide_mpong_game_lifecycle/src/broadcast_game_state/` — pure
  publisher for `mpong/state_broadcast_v1`. Verbatim.
- `apps/guide_mpong_game_lifecycle/src/guide_mpong_game_lifecycle{_app,_sup}.erl`
  — slimmed umbrella shell. Sup only supervises
  `auto_host_demo_loop_sup` (when enabled); the
  `run_game_engine_sup / listen_game_state_sup / mpong_lobby_seeker`
  children come back as those slices land. App entry no longer
  spawns the `ensure_champion` retry loop (depends on
  `register_champion`, not yet extracted).

### Pending extraction from hecate-daemon

Runtime-blocking (the slices above won't actually fire until these
land):
- `host_mpong_game/` — provides `host_game_v1` + `maybe_host_game`
- `run_game_engine/` — engine, AI, physics, paddles, obstacles, `run_game_engine_sup`
- `apps/hecate_mesh/` — `hecate_mesh:publish/2` (or replace with a
  service-local thin wrapper over `macula:publish/4`)
- `apps/shared/src/hecate_topics.erl` — topic-string builder

Then the rest of the lifecycle:
- `mpong_lobby_seeker/` — joiner-side `mpong/seat_requested_v1`
- `request_seat/ reserve_seat/ deny_seat/` — seat negotiation
- `handle_paddle_input/` — `mpong/paddle_moved_v1` subscriber
- `open_lobby/`, `register_champion/`, `start_mpong_game/`,
  `join_mpong_game/`, `listen_game_state/`,
  `end_game/`, `eliminate_player/`, `leave_game/`,
  `seek_lobby/`, `mpong_game_aggregate.erl`, `mpong_game_state.erl`
