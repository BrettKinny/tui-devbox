# Agent guidance

- Read `CLAUDE.md` for repository conventions and test commands.
- Read `CONTEXT.md` before changing architecture or behavior; consult `docs/adr/`.
- Keep changes scoped and run relevant deterministic tests. Before delivery,
  run the executable `tests/test-*.sh` suite described in `CLAUDE.md`.
- Do not weaken fail-closed artifact verification or lifecycle ownership checks.
- Do not push, release, tag, publish, change GitHub settings, or modify secrets
  unless explicitly instructed.
- Inside `sqrbx-agent`, project access is confined to `/workspace`; do not seek
  host credentials or paths outside it. Use only the supplied execution tools.

These are behavioral instructions, not a security boundary. Normal Squarebox
is a trusted development environment. See `SECURITY.md` and `docs/agent.md` for
the separate hardened agent profile.
