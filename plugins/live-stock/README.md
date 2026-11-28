# live-stock

Run a work plan's stories as parallel Claude Code lanes on GitHub.

```
/plugin install live-stock
```

| Skill | Invoke | What it does |
| - | - | - |
| [`herd`](skills/herd/README.md) | `/live-stock:herd <run-file>` | Goal-driven conductor: runs GitHub issues or local story codes from a work plan as parallel lanes (one Claude Code session per story in its own herdr pane and git worktree), answers lane gates as you would, merges approved PRs and finishes each story |

## Dependency

herd drives the [`sdlc`](../sdlc/README.md) plugin from this marketplace: each lane runs `sdlc:implement`, `sdlc:review` and `sdlc:pull-request`, and herd calls sdlc's scripts. Install sdlc alongside live-stock; `node <plugin>/skills/herd/bin/herd-env.js check` reports where it found it. herd also needs herdr, `gh`, `git` and `node`; Slack is optional and off by default.

Tests:

```bash
bash bin/test/run-structure-tests.sh
bash skills/herd/bin/test/run-herd-env-tests.sh   # and the other skills/herd/bin/test/run-*.sh suites
```

---

*Part of the [LaFollett Labs Claude plugins](../../README.md)*
