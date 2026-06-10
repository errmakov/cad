# CAD — Continuous Agentic Deployment

The **engine**: an open-source framework for AI-powered CI/CD pipelines. Agents
pull work items through a GitHub-native pipeline — issue analysis, code
generation, testing — with WIP limits, a human review gate, retries, and a
deterministic deploy.

This repo holds the framework only: reusable workflows (the stations), the
prompt library, and the orchestration scripts. The app it builds lives
separately — see **[cad-console](https://github.com/errmakov/cad-console)**, the
reference implementation (a self-observing pipeline dashboard).

> Status: **spike** — validating the two-repo reusable-workflow architecture
> before extracting the full engine from the reference implementation.

## Architecture (target)

```
cad/  (this repo — the framework)
  .github/workflows/agent-*.yml   on: workflow_call   ← stations, as reusable workflows
  prompts/                        the prompt library (behaviour = config)
  scripts/                        board reads, cost/stats, seed, dispatch helpers

cad-console/  (the app it builds)
  .github/workflows/agent-*.yml   on: workflow_dispatch -> uses: errmakov/cad/...@v1
  app/                            just the application
```

A station = a workflow + a system prompt + a WIP limit + a model + a board
column. Add one by following the shape — the engine doesn't change.

## Spike

`spike-saba.yml` proves the plumbing: dispatch-the-caller, engine-prompt access
from a reusable workflow, and `secrets: inherit`. See `SPIKE.md` for how to run it.
