# Refine Issue with LLM

A composite action for **Gitea Actions** (and GitHub Actions). Label an issue with
`refine-issue-agent`, and the action reads the repository — file tree, every
`README.md`, `AGENTS.md`/`CONTRIBUTING.md`/`docs/*.md`, and the build manifests — then appends a
detailed, project-aware description to the **issue body**:

```markdown
Original text written by the reporter.

<!-- agent:begin -->

### Summary
…
### Context
### Proposed change
### Affected files
### Acceptance criteria
### Assumptions and open questions

_Generated from the repository context by `<model>`. Review before implementing._

<!-- agent:end -->
```

The `<!-- agent:… -->` lines are the machine-readable boundary and render invisibly in Gitea,
so the reader sees the original text followed straight by the generated sections.

Any OpenAI-compatible `/chat/completions` endpoint works, including a self-hosted one.

## Repo layout

```
action.yaml          # inputs/outputs, thin composite wrapper
refine-issue.sh      # all the logic, env-driven, runnable by hand
refine-issue.yaml    # the consumer workflow
```

## Pairing with `coder-agent-action`

This is the front half of a two-step pipeline:

| label | action | result |
| --- | --- | --- |
| `refine-issue-agent` | this one | a detailed description is written into the issue body, the label is removed |
| `coder-agent` | `gitea/coder-agent-action` | a Coder workspace implements it and opens a PR |

Label, review what came back, correct it, then label `coder-agent`. That action
reads the enriched body and strips only the markers and the footer, so the
generated description reaches the implementing agent as-is. The two are
independent — either works alone — but if you run both, leave `section-begin` /
`section-end` at their defaults on both sides.

## Setup

### 1. Secrets & variables

The LLM is the same for every repository, so none of the three `ISSUE_LLM_*`
values is configured per repo:

| name | kind | set at | notes |
| --- | --- | --- | --- |
| `ISSUE_LLM_BASE_URL` | var | **admin** — *Site Administration → Actions → Variables* (Gitea 1.24+) | Base URL including the API version, e.g. `https://api.minimax.io/v1`. `/chat/completions` is appended |
| `ISSUE_LLM_MODEL` | var | **admin** — same place | Model name as the endpoint accepts it, e.g. `MiniMax-M3` |
| `ISSUE_LLM_TOKEN` | secret | **user** — *User Settings → Actions → Secrets* | Bearer token for the endpoint. Any non-empty string if it is unauthenticated |
| `GITEA_TOKEN` | *(automatic)* | — | Provided per job, scoped to the current repo — nothing to create |
| `ACTION_CLONE_TOKEN` | secret, optional | org | PAT (scope `read:repository`) used to fetch this action when it lives in another repo or org. Set once on the org so every repo inherits it |

Gitea resolves both kinds from the most specific scope outwards — **repo > org >
admin** for variables, **repo > org > user** for secrets — so a single project
that needs a different model or its own key can still set it on itself and win
over the instance-wide value.

Secrets have no admin/instance-wide scope, so `ISSUE_LLM_TOKEN` must be set on
each owner. A **user** secret covers only the repositories owned by that user
and does **not** reach a repository owned by an organization — for those, set it
on the org (`<gitea>/org/<org>/settings/actions/secrets`) or on the repo itself.
The two variables are unaffected: admin-level ones reach every repo. A run that
cannot see the secret is named in the `missing LLM settings` error.

The `ISSUE_` prefix keeps these apart from any other LLM configuration on the
instance, and it is the **same name at every layer** — the Gitea variable or
secret, the workflow's env key, the action input (`issue-llm-base-url` and
friends) and the script's env var all match, so a value can be traced end to end
by grepping one string.

The tuning inputs (`llm-timeout`, `max-tokens`, `temperature`, …) keep their
plain names: they have defaults, are never read from a Gitea variable, and are
not part of choosing *which* LLM to call. `llm-timeout` is the wall-clock
budget (in seconds, default `600`) for the completion call, and is also the
cap on the Gitea REST round trip on the same job; the consumer workflow sizes
its step at 15 minutes so a slow but successful reply still finishes with the
issue body rewritten.

Gitea rejects secret names starting with `GITEA_` or `GITHUB_`, which is why
the job token is handed to the script as `FORGE_TOKEN`.

### 2. The workflow file

Save `refine-issue.yaml` from this repo as `.gitea/workflows/refine-issue.yaml`
in the consumer repo, then create a label named **`refine-issue-agent`** in
*Issues → Labels*. Point `repository:` at wherever this action's repo actually
lives, and the `actions/checkout` URLs at your instance.

Gitea Actions resolves `uses:` **before** the job starts and cannot pass a token
to it (go-gitea/gitea#26032, #27935), and the automatic per-job token is minted
for the consumer repo only. So a private action repo has to be fetched with
`actions/checkout` + `ACTION_CLONE_TOKEN` rather than referenced with `uses:`:

```yaml
jobs:
  refine:
    runs-on: ubuntu-24.04
    if: ${{ gitea.event.action == 'label_updated' && gitea.event.changes.added_labels[0].name == 'refine-issue-agent' }}
    steps:
      # The repository being analysed — without it there is nothing to read.
      - uses: https://gitea.example.com/actions/checkout@v4

      - name: Fetch the action
        uses: https://gitea.example.com/actions/checkout@v4
        with:
          repository: gitea/refine-issue-action
          ref: main
          token: ${{ secrets.ACTION_CLONE_TOKEN || secrets.GITEA_TOKEN }}
          path: .action
          persist-credentials: false

      - name: Refine this issue
        env:
          ISSUE_LLM_BASE_URL: ${{ vars.ISSUE_LLM_BASE_URL }}
          ISSUE_LLM_MODEL:    ${{ vars.ISSUE_LLM_MODEL }}
          ISSUE_LLM_TOKEN:    ${{ secrets.ISSUE_LLM_TOKEN }}
          FORGE_TOKEN:  ${{ secrets.GITEA_TOKEN }}
        run: bash "$GITHUB_WORKSPACE/.action/refine-issue.sh"
```

`.action/` is excluded when the repository context is assembled, so the action
never describes itself to the model as if it were project code.

**Action repo public**, or in the same repo the per-job token can read? Then the
fetch step disappears and inputs replace the env vars — the project checkout is
still required:

```yaml
      - uses: https://gitea.example.com/actions/checkout@v4

      - uses: https://gitea.example.com/gitea/refine-issue-action.git@main
        with:
          issue-llm-base-url: ${{ vars.ISSUE_LLM_BASE_URL }}
          issue-llm-model:    ${{ vars.ISSUE_LLM_MODEL }}
          issue-llm-token:    ${{ secrets.ISSUE_LLM_TOKEN }}
          forge-token:  ${{ secrets.GITEA_TOKEN }}
```

## Running it by hand

Everything is env-driven, so the same script runs from any shell that can reach
both the endpoint and Gitea — `cd` into a clone of the repo to analyse:

```bash
export ISSUE_LLM_BASE_URL=https://llm.example.com/v1 ISSUE_LLM_MODEL=MiniMax-M3 ISSUE_LLM_TOKEN=... \
       FORGE_URL=https://gitea.example.com GITEA_TOKEN=... \
       REPOSITORY=owner/project ISSUE_NUMBER=42
bash refine-issue.sh
```

`GITEA_TOKEN` and `FORGE_TOKEN` are interchangeable, as in `coder-agent-action`.
Inside Actions, `FORGE_URL`, `REPOSITORY` and `ISSUE_NUMBER` all default from
the runner environment and the event payload.

## How the body is rewritten

1. The current body is read. If it already contains a `section-begin` line, everything up to
   and including the next `section-end` line is cut out.
2. What remains is the **original** text. Only that is sent to the model, so a previous
   generation is never fed back in as if the reporter had written it.
3. The new section is appended below it and the whole body is written back with
   `PATCH /repos/{owner}/{repo}/issues/{index}`.

Re-running is therefore idempotent: the section is replaced, never stacked. Any manual edits
**inside** the markers are lost on the next run; edits above them are preserved. Marker matching
is exact whole-line, and the model is instructed not to emit HTML comments — any marker lines
that slip through are filtered before the body is assembled.

### When the model returns nothing useful

When the cleanup pipeline (think-block strip + marker filter) leaves the refined section empty,
the step no longer dies with the opaque `refined description was empty after cleanup.` line. It
now distinguishes the two observable causes, writes the raw reply to disk next to the checkout,
and surfaces the reason on the `error` output:

| log line | cause |
|---|---|
| `ERROR: raw response was empty (model returned no content).` | the model returned no content at all (empty string, whitespace, or no `choices[0]`) |
| `ERROR: cleanup stripped all content; raw response was: <sanitised snippet>… (truncated, N bytes total)` | the model returned text but the post-processor ate it; the snippet is capped at 500 chars with ANSI/control characters stripped and newlines rewritten as `\n` so the log does not flood |

`finish_reason` is logged alongside so the operator can tell "model refused" (`content_filter`)
from "model truncated the response" (`length`) without opening the script. The raw reply is also
written to `~/refine-issue-debug.raw.txt` (resolved as
`${HOME:-${GITHUB_WORKSPACE:-$(pwd)}}/refine-issue-debug.raw.txt` — so the dump lands in the runner
user's home regardless of `working-directory`, the checkout path, or the runner version) — pick it
up as a workflow artifact (e.g. `actions/upload-artifact@v4`) to download it, or browse the runner
user's home in the workspace. The failure log also prints a navigable pointer to the Actions run
page (`${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}` inside a job, or the
resolved workspace path on a manual run) so the reporter does not have to copy absolute paths out
of the log to reach either the file or the run. The file is only written on the failure path, so
successful runs leave no trace.

### Running it again

The label stays on the issue after a run (`remove-label` defaults to `false`), and a label
that is already there cannot be *added* again, so no event fires. To regenerate the section,
remove `refine-issue-agent` from the issue and put it back.

That is one click more than the alternative. It buys a shorter run list: dropping the label
is itself a `label_updated` event, and Gitea starts a run of **every** label-triggered
workflow in the repo for it — each one skipping on its `if:` guard, but each one still a row
in the list. Set `remove-label: true` (or `REMOVE_LABEL: "true"` in the env-var form of the
workflow) if you would rather have the one-click re-run and live with the extra rows.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `issue-llm-base-url` | — | Base URL including the API version. `/chat/completions` is appended unless already present. |
| `issue-llm-model` | — | Model name. |
| `issue-llm-token` | — | Bearer token. |
| `forge-token` | — | Gitea token with issue write access. |
| `forge-url` | *(current server)* | Gitea base URL. Falls back to `GITHUB_SERVER_URL`. |
| `repository` | *(current repo)* | `owner/repo`. Falls back to `GITHUB_REPOSITORY`. |
| `issue-number` | *(from the event)* | Issue index. Falls back to `.issue.number` in the event payload. |
| `require-label` | `refine-issue-agent` | Exits early unless the issue currently carries this label. Set to `''` to disable. |
| `remove-label` | `false` | Keeps the label on the issue after a successful run. Set to `true` to drop it, which makes the label a one-shot button — at the cost of an extra label event, and with it a skipped run of every label-triggered workflow. |
| `section-begin` | `<!-- agent:begin -->` | Opening marker line. Invisible when rendered. |
| `section-end` | `<!-- agent:end -->` | Closing marker line. |
| `max-context-chars` | `60000` | Total repository context budget. |
| `max-file-chars` | `8000` | Per-file budget. |
| `max-tree-files` | `400` | Paths listed in the tree section. |
| `max-tokens` | `65536` | Completion budget. |
| `temperature` | `0.2` | Sampling temperature. |
| `llm-timeout` | `600` | Wall-clock budget (seconds) for the completion call; also caps the Gitea REST round trip on the same job. The consumer workflow step is sized at 15 min, so a reply that takes the full budget still completes. |
| `working-directory` | `.` | Checkout directory to analyse. |

## Outputs

| Output | Description |
| --- | --- |
| `skipped` | `true` when the run exited early because the required label was missing. |
| `issue-url` | HTML URL of the updated issue. |
| `error` | Failure reason when the run exited with a non-zero status — see [When the model returns nothing useful](#when-the-model-returns-nothing-useful). Empty on success. |

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `body contains the begin marker … but no matching end marker` | The closing marker was deleted or edited by hand. Fix the body, then re-label. |
| `no files found — did the workflow run actions/checkout?` | Missing checkout step, or wrong `working-directory`. |
| `ERROR: missing LLM settings: …` | One or more of the three is not **visible to this repository** — an unset `vars.*` / `secrets.*` expands to the empty string rather than failing the job, so nothing fails earlier. The message lists every one that is missing and which Gitea key feeds it. Most common cause: `ISSUE_LLM_TOKEN` is a **user** secret and the repository is owned by an **organisation**, which a user secret does not reach — set it on the org (or the repo). For the two variables, check *Site Administration → Actions → Variables*, or that your Gitea is 1.24+ and has admin-level variables at all. |
| `ERROR: raw response was empty (model returned no content).` | The model returned no content at all (empty string, whitespace-only, or no `choices[0]`). Check `finish_reason` — `length` means `max-tokens` is too small or the server's own output limit is misconfigured, `content_filter` means the model refused. Adaptive-thinking models can also burn the whole budget on reasoning. The `error` output is set and `~/refine-issue-debug.raw.txt` is written under the runner user's home. |
| `ERROR: cleanup stripped all content; raw response was: <snippet>… (truncated, N bytes total)` | The model replied but the post-processor ate it — usually a reply made of only `<think>…</think>` blocks, only the section markers, or only whitespace. The log line carries a sanitised 500-char snippet, the original byte count, and `finish_reason`; the full unmodified reply is in `~/refine-issue-debug.raw.txt`. |
| `GET issue … returned HTTP 404` | `forge-url` or `repository` wrong, or the token cannot see the repo. |
| `PATCH issue returned HTTP 403` | `FORGE_TOKEN` lacks `write:issue`. |
| Workflow never starts | `runs-on` must match a label the runner actually registered (check with `docker exec <runner> cat .runner`); the `if:` guard uses `gitea.event.changes.added_labels[0].name` — `gitea.event.label.name` is empty on Gitea, unlike GitHub. |
| Checkout of the action repo fails with `404` | The automatic per-job token is minted for the consumer repo only. That is what `ACTION_CLONE_TOKEN` is for — verify it is set and that its account can see the action repo. |
| The action's own files show up in the context | `.action/` is excluded by name; a different `path:` in the workflow is not. Keep it, or add yours to the exclusion list in `refine-issue.sh`. |
| Section stacked twice | The markers were changed between runs, so the old section no longer matched. |
| Markers visible in the rendered issue | Something escaped the HTML comment — check the body source for a stray backtick or code fence around them. |
| Context truncated | Raise `max-context-chars` / `max-file-chars`, mind the model's context window. |

## Notes

- Reasoning blocks wrapped in `<think>…</think>` are stripped before the body is written.
- The generated section uses `###` headings so it nests under the issue title without competing with it.
- Changing `section-begin`/`section-end` after a run orphans existing sections; the next run appends a second one.
- Vendored paths (`node_modules`, `vendor`, `.venv`, `dist`, `build`, `target`, `__pycache__`) and the action's own `.action/` checkout are excluded.
- The file list comes from `git ls-files` when the directory is a work tree, so untracked and ignored files are skipped; `find` is only the fall-back.
- Per-file truncation is byte-based, so the tail is passed through `iconv -c` to drop a half-written multi-byte character — `jq` refuses invalid UTF-8.
