# Roadmap

## Current priorities

- **Native Windows SSH-agent relay** — prototype a safe bridge for Docker
  Desktop and Podman ([#160](https://github.com/SquareWaveSystems/squarebox/issues/160)).
- **Codex app-server state** — restore opt-in state safely after Box restart
  ([#134](https://github.com/SquareWaveSystems/squarebox/issues/134)).
- **Learn mode redesign** — opt-in lessons with corrected versioned content,
  binary-based capability checks, an explicit privacy contract, and no command
  logging without informed consent.
- **User dotfile adapters** — documented merge/override behavior for Starship,
  tmux, aliases, Zsh, and Fish without weakening managed refresh safety.
- **Atuin** — persistent searchable shell history with optional sync.
- **direnv** — pinned image-tier automatic `.envrc` loading.
- **hyperfine** — pinned image-tier command benchmarking.
- **Host-theme inheritance** — ANSI-first defaults for fzf, eza, Starship,
  tmux, and Zellij with clear overrides for bat/delta themes.
- **Assistant completion notifications** — opt-in terminal bell/desktop adapter
  around long-running assistant commands.
- **Native platform depth** — improve platform adapters when concrete defects
  justify the work; do not maintain a standing manual qualification matrix.

Release qualification remains assertion-driven: every required ID in
`scripts/e2e-required.tsv` must pass against one immutable Candidate digest.
Platform-specific manual checks in `uat-checklist.md` are optional follow-up,
not an inferred release gate.
