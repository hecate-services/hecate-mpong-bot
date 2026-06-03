# PLAN: Pong Over Mesh

**Status:** Active — design locked 2026-06-03
**Repo:** `hecate-services/hecate-mpong-bot`
**Supersedes:** the `auto_host_demo_loop` self-hosted local-game model.

---

## 1. Goal & non-goals

**Goal.** A single pong game whose two paddles live on **different beam
nodes**, with all cross-node coordination and frames travelling over the
Macula mesh. The realm `/demo/mpong` page spectates a real game where wall 1
is driven by another daemon entirely.

**Non-goals (this iteration).**
- Human players. Bot-vs-bot only. (Locked: latency is cosmetic.)
- N-wall free-for-all. Strict 1v1; schemas carry `wall_index` so N-wall is a
  later config change, not a rewrite.
- Per-game mesh topics. Single tiered topic per fact type, filter by
  `game_id` in-handler (Erlang function-head match is the filter).
- Changes to the realm. It already renders `state_broadcast`; no change.

---

## 2. Locked architecture decisions

| Axis | Decision |
|------|----------|
| Authority | **Host-authoritative.** Host runs the engine (ball, collision, scoring, tick clock). Challenger sends only paddle input; host applies via `update_paddle/3`, simulates, broadcasts. |
| Players | Bot-vs-bot only. |
| Pairing | **Self-organizing**, race-free via a jittered seek window (§5). A bot is HOST xor CHALLENGER per round — never both at once. |
| Game size | Strict 1v1 (wall 0 = host local AI, wall 1 = remote). |
| Start | **No ball until paired.** Host advertises an *open* game; engine starts only when wall 1 is reserved. |
| Churn | **Pause → resume → end.** On challenger staleness: pause (freeze), grace period, resume if it returns, else end + re-advertise. |
| Domain vs facts | Game lifecycle = local event-sourced aggregate on the host. Mesh carries integration **facts** only; each inbound fact → local command via a `on_*_from_mesh_*` process manager. |
| Topics | One tiered topic per fact type under `io.macula/beam-campus/hecate/mpong/`; `game_id` in payload, matched in-handler. |
| Event-store hygiene | High-rate data (`paddle_moved`, `state_broadcast`) is **transient** — driven straight into/out of the engine, never written as domain events. Only lifecycle + scoring are events. |

---

## 3. Mesh fact contracts

All under prefix `io.macula/beam-campus/hecate/mpong/`. Wire is CBOR / raw
term (never pre-JSON). Negative ints are safe on the 4.8 station fleet.

| Fact (`<type>_v1`) | Publisher | Consumer | Rate | Payload |
|---|---|---|---|---|
| `game_advertised` | host | seekers, realm | ~0.1 Hz (reannounce 10s) | `{game_id, host_node_id, open_walls:[1], advertised_at}` |
| `game_withdrawn` | host/seeker | seekers | once | `{game_id, host_node_id, reason}` |
| `seat_requested` | challenger | host | once/attempt | `{game_id, challenger_node_id, wall_index:1, requested_at}` |
| `seat_reserved` | host | challenger | once | `{game_id, host_node_id, challenger_node_id, wall_index:1, reserved_at}` |
| `seat_denied` | host | challenger | once | `{game_id, host_node_id, challenger_node_id, reason}` |
| `paddle_moved` | challenger | host | tick-throttled (~every 3rd tick) | `{game_id, wall_index, y, tick}` **transient** |
| `state_broadcast` | host | challenger, realm | every 5th tick (exists) | `{game_id, ball, walls{...}, scores, tick}` **transient** |
| `game_ended` | host | challenger, realm | once | `{game_id, host_node_id, reason, final_scores}` |

`game_advertised`, `state_broadcast` already exist and keep their shapes.

---

## 4. Event-sourced model (host aggregate)

`mpong_game_aggregate` — status as integer **bit flags**
(`evoq_bit_flags`), not atoms:

```
?ADVERTISED  1    % open game published, awaiting a seat request
?SEATED      2    % wall 1 reserved to a challenger
?RUNNING     4    % engine ticking
?PAUSED      8    % challenger stale, frozen, grace timer running
?ENDED      16    % concluded; re-advertise spawns a NEW game_id
```

**Commands → events (host, event-sourced):**

| Command | Event | Transition |
|---|---|---|
| `host_open_game_v1` | `open_game_hosted_v1` | → ADVERTISED |
| `reserve_seat_v1` | `seat_reserved_v1` | ADVERTISED → SEATED |
| `deny_seat_v1` | `seat_denied_v1` | (no transition; loser re-seeks) |
| `start_game_v1` | `game_started_v1` | SEATED → RUNNING |
| `pause_game_v1` | `game_paused_v1` | RUNNING → PAUSED |
| `resume_game_v1` | `game_resumed_v1` | PAUSED → RUNNING |
| `end_game_v1` | `game_ended_v1` | * → ENDED |
| `withdraw_game_v1` | `game_withdrawn_v1` | ADVERTISED → ENDED |

Scoring stays event-sourced (`point_scored_v1`). **Paddle positions are
NOT events** — `update_paddle/3` casts straight into the engine process.

**Challenger** holds no game aggregate. It is an integration actor:
discover → request seat → on reservation, run a paddle-AI loop that reads the
host's `state_broadcast` and publishes `paddle_moved`.

---

## 5. Self-organizing role state machine (per bot, race-free)

The key to avoiding dual-commit: **a bot never advertises and seeks at the
same time.** Role is decided by a jittered seek window.

```
        boot
         │
         ▼
   ┌──────────┐  heard an open game within window      ┌─────────────┐
   │ SEEKING  │ ─────────────────────────────────────▶ │ CHALLENGER  │
   │ (listen  │                                          │ request_seat │
   │  game_   │  window expired, none heard              └──────┬──────┘
   │  advert. │ ─────────────────┐                              │
   │  for     │                  ▼                       seat_reserved? ─▶ PLAYING_REMOTE
   │  jitter  │            ┌──────────┐                  seat_denied?   ─▶ SEEKING
   │  0..5s)  │            │  HOST    │
   └──────────┘            │ advertise │ seat_requested ─▶ reserve (first wins) ─▶ PLAYING_HOST
                           │  open game│ no seat in T    ─▶ re-advertise / back to SEEKING
                           └──────────┘
```

- **SEEKING:** subscribe `game_advertised`; wait a *jittered* `0..SEEK_MS`.
  Booting bots stagger naturally → earliest become hosts, rest join.
- **CHALLENGER:** publish `seat_requested` for the chosen open game (pick
  lowest `game_id` to damp collisions). Await `seat_reserved` / `seat_denied`.
  Denied → back to SEEKING.
- **HOST:** publish `game_advertised` (reannounce every 10s). First
  `seat_requested` → `reserve_seat` → `start_game`; later requests → deny.
  No seat within `HOST_WAIT_MS` → re-advertise or drop to SEEKING.
- **PLAYING_REMOTE:** subscribe the host's `state_broadcast`, run `mpong_ai`
  on the ball to compute wall-1 `y`, publish `paddle_moved` (throttled). On
  `game_ended` (or seat lost) → SEEKING.
- **PLAYING_HOST:** engine runs wall 0 (local AI) + wall 1 (remote). On
  `game_ended` → SEEKING.

Per-bot commit is single: a bot is in exactly one of SEEKING / CHALLENGER /
HOST / PLAYING_* at a time, so the host-vs-challenger double-commit race
cannot occur. The only remaining race (two challengers, one seat) resolves
host-side first-wins; the loser returns to SEEKING.

---

## 6. Vertical slices

All desks under `apps/guide_mpong_game_lifecycle/src/`. Integration
emitters/listeners are **sibling slices** in the same CMD app (own dir, own
`_sup`, own gen_server), not nested in the desks they trigger.

### Host desks
- `advertise_game/` *(modify)* — advertise an **open** game (1 local paddle,
  open wall 1); reannounce heartbeat.
- `reserve_seat/` *(new)* — `maybe_reserve_seat`: first request → reserve +
  start; subsequent → deny.
- `run_game_engine/` *(modify)* — start with `player_modes => #{0 => {bot,_},
  1 => remote}`; honour `update_paddle/3` for wall 1; pause/resume; staleness
  watchdog (no `paddle_moved` for `STALE_MS` → `pause_game`, grace → `end_game`).
- `broadcast_game_state/` *(exists)* — unchanged.
- `withdraw_game/` *(new)* — `game_withdrawn` when a seeker/host abandons its ad.

### Challenger desks
- `discover_games/` *(new)* — the role state machine (§5): subscribe
  `game_advertised`, jittered seek window, select/commit.
- `request_seat/` *(new)* — publish `seat_requested`; track the awaited game.
- `play_remote_paddle/` *(new)* — on reservation: consume host
  `state_broadcast`, run `mpong_ai`, publish `paddle_moved`; stop on end.

### Integration sibling slices (mesh facts)
Emitters:
- `emit_game_advertised_to_mesh` *(exists as advertise_game:announce — formalize)*
- `emit_seat_reserved_to_mesh`, `emit_seat_denied_to_mesh`
- `emit_seat_requested_to_mesh`
- `emit_paddle_moved_to_mesh`
- `emit_state_broadcast_to_mesh` *(exists as broadcast_game_state)*
- `emit_game_ended_to_mesh`

Listeners (process managers, inbound fact → local command/cast):
- `on_game_advertised_from_mesh_request_seat` *(challenger)*
- `on_seat_requested_from_mesh_reserve_seat` *(host)*
- `on_seat_reserved_from_mesh_begin_play` *(challenger)*
- `on_seat_denied_from_mesh_reseek` *(challenger)*
- `on_paddle_moved_from_mesh_update_paddle` *(host → engine cast; NO event)*
- `on_state_broadcast_from_mesh_feed_paddle_ai` *(challenger → play loop)*
- `on_game_ended_from_mesh_reseek` *(challenger)*

### Removed
- `auto_host_demo_loop/` — replaced by `discover_games/` + `advertise_game/`
  open-game flow. (`mpong_auto_host_*` env knobs retired; bot count is moot —
  one bot per node hosts/joins exactly one game.)

---

## 7. Infrastructure: mesh subscribe

`hecate_mesh` is publish-only today. Add subscribe in the bot's shim — the
SDK supports it and `hecate_om` holds the pool (`macula_client/0`), so **no
hecate_om hex release is needed**.

- `hecate_mesh:subscribe/2` → `macula:subscribe(Pool, Topic, Handler)`.
  Confirm SDK delivery mode (callback fun vs process mailbox) and wire the
  handler to forward into the owning process.
- **Subscription lifecycle:** subscriptions are **long-lived, per fact type**
  (NOT per game) — established once when the pool attaches, filtered by
  `game_id` in-handler. `hecate_om` already monitors + re-attaches the pool on
  disconnect; a small subscription manager must **re-subscribe on pool
  change**. No per-game subscribe/unsubscribe churn, no teardown on game end.
- Topics a bot subscribes to (stable set): `game_advertised`, `seat_requested`,
  `seat_reserved`, `seat_denied`, `paddle_moved`, `state_broadcast`,
  `game_ended`. Each handler matches on the bot's current role + `game_id` and
  drops the rest (catch-all clause).

---

## 8. Failure / churn handling

- **Challenger stale** (host sees no `paddle_moved` for `STALE_MS`): host
  `pause_game` (freeze wall 1), start grace timer `GRACE_MS`. If
  `paddle_moved` resumes → `resume_game`. Else `end_game` + emit `game_ended`,
  return host to SEEKING (which re-advertises a fresh `game_id`).
- **Host gone** (challenger's `state_broadcast` dries up for `STALE_MS`):
  challenger abandons → SEEKING.
- **Seat lost / denied:** challenger → SEEKING.
- Re-advertise always mints a **new `game_id`** (single-topic-filter makes this
  free — no topic teardown).

---

## 9. Build phases (ordered, each independently testable)

1. **Mesh subscribe primitive.** `hecate_mesh:subscribe/2` + subscription
   manager + re-subscribe on pool change. Test: subscribe to a topic, publish
   from a second node, assert delivery. *Unblocks everything.*
2. **Engine remote wall.** Wire `update_paddle/3` into the tick loop for a
   `remote` wall; `player_modes => #{1 => remote}`; pause/resume. Test
   locally: feed synthetic paddle casts, assert wall 1 tracks; assert pause
   freezes ball.
3. **Seat negotiation (host).** `host_open_game`, `reserve_seat`/`deny_seat`,
   `start_game`; emitters + `on_seat_requested_from_mesh_reserve_seat`. Test:
   two synthetic `seat_requested` → one reserved, one denied.
4. **Challenger side.** `discover_games` role SM, `request_seat`,
   `play_remote_paddle` (AI from `state_broadcast` → `paddle_moved`).
5. **Wire it end-to-end** two nodes: host advertises, challenger joins, ball
   starts, wall 1 tracks remote paddle, realm spectates.
6. **Churn.** Staleness watchdog → pause → resume/end; re-advertise; verify
   self-re-pairing after a node bounce.
7. **Fleet.** Deploy to 4 beams (one bot/node), confirm ~2 emergent 1v1 games,
   each spanning two nodes, visible on `/demo/mpong`.

---

## 10. Test strategy

- **Per desk (eunit):** handler tests (`maybe_*` cmd → event), aggregate
  transitions (bit-flag state machine), role-SM transitions. Tests live in
  `apps/<app>/test/` as eunit — never `/tmp`.
- **Integration:** seat negotiation (request → reserve/deny), engine remote
  paddle tracking, pause/resume.
- **Live mesh:** two-node manual run, then 4-beam deploy via
  `scripts/deploy-bots.sh` + `logs` verification (assert each node logs the
  remote game_id it joined/hosts, `paddle_moved` both directions,
  `state_broadcast` flowing, zero `mesh_unavailable`).

---

## 11. Open questions / risks

- **SDK subscribe delivery contract** (callback vs mailbox, backpressure,
  ordering) — verify against the macula SDK before phase 1.
- **`paddle_moved` rate vs smoothness** — start every-3rd-tick + receiver-side
  interpolation; tune on live mesh.
- **Seek-window jitter tuning** — `SEEK_MS` / jitter spread vs how fast 4 bots
  converge to 2 games; measure on the fleet.
- **Spectator vs challenger on the same `state_broadcast`** — both consume it;
  ensure the challenger's AI read path and the realm's render path don't
  interfere (they're independent subscribers; should be fine).

---

## 12. Out of scope (future)

- Human-controlled paddles from `/demo/mpong` (reintroduces latency as a real
  UX constraint → prediction/rollback).
- N-wall free-for-all (schemas already carry `wall_index`).
- Per-game topics + subscription-lifecycle manager (only if concurrent-game
  count grows enough that per-node filter/decode cost becomes real).
- Cross-realm / federated matchmaking.

---

## Follow-up

- Reflect this plan in the master index
  `macula-internal/macula-architecture/plans/PLAN_MACULA_ROOT.md` (per the
  workspace plan-structure convention).
