# Contributing

Trunk-based. Commit directly to `main`. No PRs, no feature branches.

## Build

```bash
rebar3 compile
rebar3 ct
```

Or via the container:

```bash
podman build -t hecate-rag:dev .
podman run --rm hecate-rag:dev /app/bin/hecate-rag eval 'hecate_rag:info().'
```

## Style

- Erlang: `warnings_as_errors`, dialyzer clean
- Vertical slicing only — no `services/`, `helpers/`, `utils/`
- Slices live under `apps/<cmd-app>/src/<slice>/{cmd, event, handler, api}.erl`

## Regenerating slice stubs

```bash
python3 scripts/scaffold-slices.py
```

Idempotent. Touches only the slice files; leaves umbrella roots
(app.src, _app.erl, _sup.erl) alone.

## Issues

https://codeberg.org/hecate-services/hecate-rag/issues
