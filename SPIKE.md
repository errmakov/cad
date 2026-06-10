# CAD plumbing spike — how to run it

Goal: prove the **two-repo reusable-workflow** architecture works before
extracting the full engine. Three questions, one cheap run (no Anthropic API call):

| | Question | Proven by |
|---|---|---|
| Q1 | Dispatch-the-caller: can the app repo dispatch a shim that runs the engine's reusable workflow? | the run starting at all + the issue comment |
| Q2 | Engine-prompt access: can a reusable workflow read `prompts/` from `cad`? | the `cat engine/prompts/saba-system.md` step |
| Q3 | Secret inheritance: does `secrets: inherit` carry `ANTHROPIC_API_KEY`? | the "present (length N)" line |

## One-time setup (you run these — outward-facing)

```bash
# 1. Publish the engine (public so a private caller can `uses:` it; it has no secrets)
cd ~/www/cad
git init && git add -A && git commit -m "spike: reusable saba + engine prompt"
gh repo create errmakov/cad --public --source=. --remote=origin --push

# 2. Publish the demo/app repo (private is fine for the spike)
cd ~/www/cad-console
git init && git add -A && git commit -m "spike: thin saba caller -> cad"
gh repo create errmakov/cad-console --private --source=. --remote=origin --push

# 3. Secrets on the CALLER repo (cad-console) — inherited into the reusable workflow.
#    Use your real values; do NOT paste them into any file.
gh secret set ANTHROPIC_API_KEY -R errmakov/cad-console      # paste when prompted
gh secret set PROJECT_PAT       -R errmakov/cad-console      # PAT: repo + workflow scopes

# 4. A target issue for the comment to land on
gh issue create -R errmakov/cad-console --title "spike target" --body "plumbing test"
#   note the issue number it prints (e.g. 1)
```

## Run it

```bash
gh workflow run agent-saba.yml -R errmakov/cad-console -f issue_number=1
gh run watch  -R errmakov/cad-console
```

## Green = all three of these

- The run **starts** and the `saba` job resolves `uses: errmakov/cad/...@main`  -> **Q1**
- Step "Q2 — prove prompt access" prints the engine prompt + `OK: engine prompt is readable`  -> **Q2**
- Step "Q3 — prove secret inheritance" prints `OK: ANTHROPIC_API_KEY present (length …)`  -> **Q3**
- A ✅ comment appears on the cad-console issue.

## If it's red

- **`uses:` can't find the workflow** -> confirm `cad` is pushed to `main` and is public (or grant
  the caller access under `cad` -> Settings -> Actions -> General -> Access).
- **Q3 empty** -> the secret isn't on the **caller** repo, or you declared but didn't inherit it.
- **Checkout of the app repo fails** -> `PROJECT_PAT` lacks `repo` scope / can't read `cad-console`.

Once green, the architecture is validated — proceed to extract the real stations
(agent-saba/dev/test/fix/resolve/deploy) from the reference implementation into
`cad` as reusable workflows, and replace this spike.
