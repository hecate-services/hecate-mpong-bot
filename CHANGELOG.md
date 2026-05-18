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
- `apps/` umbrella empty; game-lifecycle slices still live in
  `hecate-daemon/apps/guide_mpong_game_lifecycle` pending extraction.

### Pending extraction from hecate-daemon

- `run_game_engine/` — engine, AI, physics, paddles, obstacles
- `advertise_game/` — `mpong/game_advertised_v1` publisher
- `broadcast_game_state/` — `mpong/state_broadcast_v1` publisher
- `auto_host_demo_loop/` — autonomous match scheduler
- `mpong_lobby_seeker/` — joiner-side `mpong/seat_requested_v1`
- `request_seat/ reserve_seat/ deny_seat/` — seat negotiation
- `handle_paddle_input/` — `mpong/paddle_moved_v1` subscriber
- `open_lobby/`, `register_champion/`, `start_mpong_game/`,
  `host_mpong_game/`, `join_mpong_game/`, `listen_game_state/`,
  `end_game/`, `eliminate_player/`, `leave_game/`,
  `seek_lobby/`, `mpong_game_aggregate.erl`, `mpong_game_state.erl`
