#!/usr/bin/env bash
# Refine a short Gitea issue into a project-aware description and write it
# into a delimited section of the issue body.
set -euo pipefail

log()  { printf '%s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
out()  { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT" || true; }

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "required binary not found: $bin"
done

# Gitea Actions forbids secrets named GITEA_*, so the token arrives as
# FORGE_TOKEN there; a plain shell can just export GITEA_TOKEN. Same contract
# as coder-agent-issue.sh, so both actions take the same env.
FORGE_TOKEN="${FORGE_TOKEN:-${GITEA_TOKEN:-}}"
: "${FORGE_TOKEN:?set FORGE_TOKEN (CI) or GITEA_TOKEN (shell) — needs issue write scope}"
# Report every missing LLM setting at once. An unset Gitea variable or secret
# expands to the empty string rather than failing the job, so all three go
# missing together far more often than one alone — failing on the first would
# just hide the other two until the next run.
missing=""
[ -n "${ISSUE_LLM_BASE_URL:-}" ] || missing="${missing}
  issue-llm-base-url  <- vars.ISSUE_LLM_BASE_URL   (admin variable)"
[ -n "${ISSUE_LLM_MODEL:-}" ]    || missing="${missing}
  issue-llm-model     <- vars.ISSUE_LLM_MODEL      (admin variable)"
[ -n "${ISSUE_LLM_TOKEN:-}" ]    || missing="${missing}
  issue-llm-token     <- secrets.ISSUE_LLM_TOKEN   (user secret)"
if [ -n "$missing" ]; then
  die "missing LLM settings:${missing}

An unset Gitea variable or secret expands to an empty string, so check each one
is both SET and VISIBLE to this repository. Resolution is repo > org > admin for
variables and repo > org > user for secrets — note a USER secret does not reach a
repository owned by an ORGANISATION; set it on the org (or the repo) as well."
fi

# --- fall-backs from the runner environment, so the script is also runnable
# --- by hand: export the same vars, then `bash refine-issue.sh`.
FORGE_URL="${FORGE_URL:-${GITHUB_SERVER_URL:-}}"
FORGE_URL="${FORGE_URL%/}"
: "${FORGE_URL:?could not determine the Gitea URL — set forge-url}"

REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-}}"
: "${REPOSITORY:?could not determine owner/repo — set repository}"

ISSUE_NUMBER="${ISSUE_NUMBER:-}"
if [ -z "$ISSUE_NUMBER" ] && [ -f "${GITHUB_EVENT_PATH:-/nonexistent}" ]; then
  ISSUE_NUMBER=$(jq -r '.issue.number // empty' "$GITHUB_EVENT_PATH")
fi
: "${ISSUE_NUMBER:?no issue number — set issue-number or trigger on an issue event}"

ISSUE_LLM_BASE_URL="${ISSUE_LLM_BASE_URL%/}"
MAX_CONTEXT_CHARS="${MAX_CONTEXT_CHARS:-60000}"
MAX_FILE_CHARS="${MAX_FILE_CHARS:-8000}"
MAX_TREE_FILES="${MAX_TREE_FILES:-400}"
MAX_TOKENS="${MAX_TOKENS:-65536}"
TEMPERATURE="${TEMPERATURE:-0.2}"
# LLM_TIMEOUT bounds every curl call this script makes: the completion request
# below uses it directly, and forge() applies it to the Gitea REST round trip
# too, so a slow Gitea instance cannot make the wall-clock budget for the LLM
# call shorter than the value the user picked. ${VAR:-default} covers BOTH
# unset and explicitly-empty values, so a workflow that clears the env var by
# mistake still gets the 600s the action documents, never a curl default of 60.
LLM_TIMEOUT="${LLM_TIMEOUT:-600}"
SECTION_BEGIN="${SECTION_BEGIN:-<!-- agent:begin -->}"
SECTION_END="${SECTION_END:-<!-- agent:end -->}"
# No colon in the expansion on purpose: unset falls back to the default, but an
# explicitly EMPTY value stays empty, which is how require-label is switched off.
# action.yaml always sets these, so this default is what the env-var form of the
# workflow (the actions/checkout fetch pattern) relies on.
REQUIRE_LABEL="${REQUIRE_LABEL-refine-issue-agent}"
# Off by default: dropping the label is itself a label_updated event, and Gitea
# starts a run of every label-triggered workflow for it — all of them skipping,
# but all of them showing up in the run list. Keeping the label costs one extra
# click to re-run and keeps the list readable.
REMOVE_LABEL="${REMOVE_LABEL:-false}"

case "$ISSUE_LLM_BASE_URL" in
  */chat/completions) LLM_ENDPOINT="$ISSUE_LLM_BASE_URL" ;;
  *)                  LLM_ENDPOINT="${ISSUE_LLM_BASE_URL}/chat/completions" ;;
esac

API="${FORGE_URL}/api/v1/repos/${REPOSITORY}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ forge helper
forge() { # method path outfile [curl args...]
  local method="$1" path="$2" outfile="$3"; shift 3
  curl -sS -o "$outfile" -w '%{http_code}' -X "$method" \
    --max-time "$LLM_TIMEOUT" \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    "${API}${path}" "$@"
}

# -------------------------------------------------------------------- read issue
code="$(forge GET "/issues/${ISSUE_NUMBER}" "$WORK/issue.json")"
[ "$code" = "200" ] || die "GET issue ${ISSUE_NUMBER} returned HTTP ${code}: $(head -c 400 "$WORK/issue.json")"

TITLE="$(jq -r '.title // ""'              "$WORK/issue.json")"
AUTHOR="$(jq -r '.user.login // "unknown"' "$WORK/issue.json")"
jq -r '.body // ""' "$WORK/issue.json" > "$WORK/body-current.md"

if [ -n "$REQUIRE_LABEL" ]; then
  if ! jq -e --arg l "$REQUIRE_LABEL" 'any(.labels[]?; .name == $l)' "$WORK/issue.json" >/dev/null; then
    log "Issue #${ISSUE_NUMBER} does not carry label '${REQUIRE_LABEL}' — nothing to do."
    out skipped true
    out issue-url ""
    exit 0
  fi
fi
out skipped false

# ---------------------------------------------- strip a previous agent section, if any
# The original text is what gets sent to the model; a previous generation must
# never be fed back in as if the author had written it.
BEGIN_LINE="$(grep -nxF "$SECTION_BEGIN" "$WORK/body-current.md" | head -n 1 | cut -d: -f1 || true)"
if [ -n "$BEGIN_LINE" ]; then
  END_LINE="$(awk -v s="$BEGIN_LINE" -v e="$SECTION_END" 'NR > s && $0 == e { print NR; exit }' "$WORK/body-current.md")"
  [ -n "$END_LINE" ] || die "issue body contains the begin marker '${SECTION_BEGIN}' but no matching end marker '${SECTION_END}'. Fix the body manually before re-running."
  sed "${BEGIN_LINE},${END_LINE}d" "$WORK/body-current.md" > "$WORK/body-original.md"
  log "Replacing an existing agent section (lines ${BEGIN_LINE}-${END_LINE})."
else
  cp "$WORK/body-current.md" "$WORK/body-original.md"
fi

# drop trailing blank lines so the appended section sits flush
awk 'NF { last = NR } { lines[NR] = $0 } END { for (i = 1; i <= last; i++) print lines[i] }' \
  "$WORK/body-original.md" > "$WORK/body-trimmed.md"

# ---------------------------------------------------------------- gather context
CTX="$WORK/context.md"
: > "$CTX"

ctx_used() { wc -c < "$CTX" | tr -d ' '; }

# Drop anything that isn't valid UTF-8 (binary blobs, half-cut characters).
# iconv -c omits invalid characters but still exits 1 on an incomplete sequence
# at end of input -- which is precisely the case here -- so swallow that, and
# its warning with it, or pipefail would abort the run.
if command -v iconv >/dev/null 2>&1; then
  scrub_utf8() { iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true; }
else
  scrub_utf8() { tr -d '\000'; }
fi

add_section() { # heading file
  local heading="$1" file="$2" remaining cap
  [ -f "$file" ] || return 0
  remaining=$(( MAX_CONTEXT_CHARS - $(ctx_used) ))
  [ "$remaining" -gt 600 ] || return 0
  cap="$MAX_FILE_CHARS"
  [ "$cap" -gt "$remaining" ] && cap="$remaining"
  {
    printf '\n### %s\n\n```\n' "$heading"
    # head -c cuts on a byte boundary, so a multi-byte character can end up
    # half-written; jq --rawfile refuses the resulting invalid UTF-8.
    head -c "$cap" "$file" | scrub_utf8
    printf '\n```\n'
  } >> "$CTX"
}

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git ls-files > "$WORK/all-files.txt" 2>/dev/null || : > "$WORK/all-files.txt"
else
  find . -type f -not -path './.git/*' | sed 's|^\./||' > "$WORK/all-files.txt"
fi

# .action/ is where the consumer workflow checks THIS action out (see
# refine-issue.yaml) — it is not part of the project and must not be described
# back to the model as if it were. git ls-files already omits it (untracked);
# the find fall-back does not.
grep -Ev '(^|/)(node_modules|vendor|\.venv|venv|dist|build|target|\.next|__pycache__|\.action)/' \
  "$WORK/all-files.txt" > "$WORK/files.txt" || : > "$WORK/files.txt"

FILE_COUNT="$(wc -l < "$WORK/files.txt" | tr -d ' ')"
[ "$FILE_COUNT" -gt 0 ] || log "WARNING: no files found — did the workflow run actions/checkout?"

# 1) file tree
head -n "$MAX_TREE_FILES" "$WORK/files.txt" > "$WORK/tree.txt"
{
  printf '### Repository file tree (%s of %s paths)\n\n```\n' \
    "$(wc -l < "$WORK/tree.txt" | tr -d ' ')" "$FILE_COUNT"
  cat "$WORK/tree.txt"
  printf '```\n'
} >> "$CTX"

# 2) READMEs — root first, then the rest
grep -Ei '(^|/)readme(\.md|\.rst|\.txt|\.adoc)?$' "$WORK/files.txt" > "$WORK/readmes.txt" || : > "$WORK/readmes.txt"
awk '{ print (index($0, "/") ? 1 : 0) "\t" length($0) "\t" $0 }' "$WORK/readmes.txt" \
  | sort -k1,1n -k2,2n | cut -f3- > "$WORK/readmes-sorted.txt"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  add_section "README: $f" "$f"
done < "$WORK/readmes-sorted.txt"

# 3) agent / contributor instructions
grep -Ei '(^|/)(AGENTS\.md|CLAUDE\.md|CONTRIBUTING\.md|ARCHITECTURE\.md|docs/[^/]*\.md)$' \
  "$WORK/files.txt" | head -n 12 > "$WORK/docs.txt" || : > "$WORK/docs.txt"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  add_section "Doc: $f" "$f"
done < "$WORK/docs.txt"

# 4) manifests / build definitions
grep -Ei '(^|/)(package\.json|pyproject\.toml|requirements[^/]*\.txt|setup\.cfg|go\.mod|Cargo\.toml|composer\.json|Gemfile|pom\.xml|build\.gradle[^/]*|Makefile|Dockerfile[^/]*|docker-compose[^/]*\.ya?ml|action\.ya?ml|[^/]*\.tf)$' \
  "$WORK/files.txt" | head -n 20 > "$WORK/manifests.txt" || : > "$WORK/manifests.txt"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  add_section "Manifest: $f" "$f"
done < "$WORK/manifests.txt"

log "Context assembled: $(ctx_used) chars (limit ${MAX_CONTEXT_CHARS})."

# ---------------------------------------------------------------- build request
SYSTEM_PROMPT='You are a senior engineer triaging issues for a specific software project.

You are given the repository context (file tree, READMEs, docs, manifests) and a short issue.
Write a detailed, implementation-ready description of that issue, fitted to THIS project.

Rules:
- Ground every statement in the provided context. Never invent files, commands, endpoints or dependencies that are not visible in it.
- Where the issue is ambiguous, state the assumption explicitly instead of guessing silently.
- Use the projects own vocabulary, paths, tooling and conventions.
- Keep the original intent. Do not widen the scope.
- Do not repeat the original issue text verbatim; it stays directly above your output.
- Reply in the language of the issue text.
- Output GitHub-flavoured Markdown only, no preamble, no code fences around the whole answer.
- Do not use level 1 or level 2 headings, and do not emit HTML comments.

Use exactly these sections:
### Summary
### Context
### Proposed change
### Affected files
### Acceptance criteria
### Assumptions and open questions'

{
  printf '## Repository context\n\nRepository: %s\n' "$REPOSITORY"
  cat "$CTX"
  printf '\n\n## Issue to refine\n\nIssue number: #%s\nReported by: %s\nTitle: %s\n\nBody:\n"""\n' \
    "$ISSUE_NUMBER" "$AUTHOR" "$TITLE"
  cat "$WORK/body-trimmed.md"
  printf '\n"""\n'
} > "$WORK/prompt.txt"

jq -n \
  --arg model "$ISSUE_LLM_MODEL" \
  --arg system "$SYSTEM_PROMPT" \
  --rawfile user "$WORK/prompt.txt" \
  --argjson max_tokens "$MAX_TOKENS" \
  --argjson temperature "$TEMPERATURE" \
  '{
     model: $model,
     max_tokens: $max_tokens,
     temperature: $temperature,
     stream: false,
     messages: [
       { role: "system", content: $system },
       { role: "user",   content: $user }
     ]
   }' > "$WORK/request.json"

log "Calling ${LLM_ENDPOINT} with model ${ISSUE_LLM_MODEL} ($(wc -c < "$WORK/request.json" | tr -d ' ') bytes)."

code="$(curl -sS -o "$WORK/response.json" -w '%{http_code}' \
  --max-time "$LLM_TIMEOUT" \
  -H "Authorization: Bearer ${ISSUE_LLM_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d @"$WORK/request.json" \
  "$LLM_ENDPOINT")"

[ "$code" = "200" ] || die "completion request returned HTTP ${code}: $(head -c 600 "$WORK/response.json")"

# Extract both the raw reply and the cleaned-up version so the failure
# diagnostic below can tell "model returned nothing" apart from "model
# replied but the post-processor ate it". `${VAR:-default}` would paper over
# an unset field as empty, which is what we want for diagnostics; an unset
# jq field falls through `// ""` to the empty string the same way.
RAW_REPLY="$(jq -r '.choices[0].message.content // ""' "$WORK/response.json")"
FINISH="$(jq -r '.choices[0].finish_reason // "unknown"' "$WORK/response.json")"

# Strip leaked reasoning blocks, and any line that would collide with the markers.
printf '%s\n' "$RAW_REPLY" \
  | sed '/<think>/,/<\/think>/d' \
  | grep -vxF -e "$SECTION_BEGIN" -e "$SECTION_END" > "$WORK/refined.md" || true

CLEANED_REPLY="$(cat "$WORK/refined.md")"
# Whitespace-only strings are functionally empty here: a model that emits
# only `\n` (or only spaces) is in the same case as one that emits nothing.
RAW_TRIMMED="${RAW_REPLY//[[:space:]]/}"
CLEANED_TRIMMED="${CLEANED_REPLY//[[:space:]]/}"
RAW_BYTES=${#RAW_REPLY}

# The cleanup pipeline can leave refined.md empty in two distinct ways: the
# model returned nothing in the first place, or it returned text that the
# post-processor ate. The old single-line error hid both; this block logs
# which one happened, dumps the raw reply to disk so triage does not need
# a local re-run, and surfaces the reason on the composite action's `error`
# output. Only the failure path writes the debug file — successful runs
# leave no trace.
if [ -z "$CLEANED_TRIMMED" ]; then
  # Always land the dump in the invoking user's home so the file is easy to
  # find in the log — the absolute checkout path depends on the runner version
  # and the GITHUB_WORKSPACE prefix is brittle to read back. HOME may be
  # empty on a sandboxed runner, so fall back to the workspace / cwd before
  # giving up. Resolve it explicitly rather than relying on `~` expansion, so
  # the script still works when invoked by hand.
  DEBUG_HOME="${HOME:-${GITHUB_WORKSPACE:-$(pwd)}}"
  DEBUG_FILE="${DEBUG_HOME%/}/refine-issue-debug.raw.txt"
  if printf '%s' "$RAW_REPLY" > "$DEBUG_FILE" 2>/dev/null; then
    log "Raw reply written to ~/refine-issue-debug.raw.txt (failure path only)."
  else
    log "WARNING: could not write debug file ${DEBUG_FILE}."
  fi
  log "finish_reason=${FINISH}"

  # Print a navigable pointer to the run page so the reporter doesn't have
  # to fish absolute paths out of the log. The Actions link is only
  # constructable inside a job; on a manual run $GITHUB_REPOSITORY /
  # $GITHUB_RUN_ID are empty and we fall back to the resolved workspace
  # path so the operator still has a place to look.
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_SERVER_URL:-}" ]; then
    log "Run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  else
    log "Workspace: ${DEBUG_HOME}"
  fi

  if [ -z "$RAW_TRIMMED" ]; then
    # raw_reply was empty / unset: "model returned nothing"
    log "ERROR: raw response was empty (model returned no content)."
    out error "raw response was empty (model returned no content)."
  else
    # raw_reply non-empty but cleaned_reply empty: "model replied but the
    # post-processor ate it" — the case the operator most needs to see.
    # Sanitise: replace newlines with literal \n, strip ANSI/control chars
    # so a hostile or huge reply does not flood the log, then cap at 500
    # chars and append a truncation marker when the raw reply is longer.
    snippet=$(printf '%s\n' "$RAW_REPLY" \
      | sed -e ':a;N;$!ba;s/\n/\\n/g' \
      | sed -e $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' \
            -e 's/[[:cntrl:]]//g' \
      | head -c 500)
    if [ "$RAW_BYTES" -gt 500 ]; then
      log "ERROR: cleanup stripped all content; raw response was: ${snippet}… (truncated, ${RAW_BYTES} bytes total)"
    else
      log "ERROR: cleanup stripped all content; raw response was: ${snippet}"
    fi
    out error "cleanup stripped all content."
  fi
  exit 1
fi

# ---------------------------------------------------------------- write back the issue body
{
  cat "$WORK/body-trimmed.md"
  printf '\n\n%s\n\n' "$SECTION_BEGIN"
  cat "$WORK/refined.md"
  printf '\n_Generated from the repository context by `%s`. Review before implementing._\n\n%s\n' \
    "$ISSUE_LLM_MODEL" "$SECTION_END"
} > "$WORK/body-new.md"

jq -n --rawfile body "$WORK/body-new.md" '{ body: $body }' > "$WORK/patch.json"

code="$(forge PATCH "/issues/${ISSUE_NUMBER}" "$WORK/updated.json" -d @"$WORK/patch.json")"
case "$code" in
  200|201) : ;;
  *) die "PATCH issue returned HTTP ${code}: $(head -c 400 "$WORK/updated.json")" ;;
esac

ISSUE_URL="$(jq -r '.html_url // ""' "$WORK/updated.json")"
out issue-url "$ISSUE_URL"
log "Issue body updated: ${ISSUE_URL}"

# ---------------------------------------------------------------- drop the trigger
if [ "$REMOVE_LABEL" = "true" ] && [ -n "$REQUIRE_LABEL" ]; then
  LABEL_ID="$(jq -r --arg l "$REQUIRE_LABEL" '[.labels[]? | select(.name == $l) | .id][0] // ""' "$WORK/issue.json")"
  if [ -n "$LABEL_ID" ]; then
    code="$(forge DELETE "/issues/${ISSUE_NUMBER}/labels/${LABEL_ID}" "$WORK/unlabel.json")"
    case "$code" in
      204|200) log "Removed label '${REQUIRE_LABEL}' — re-apply it to regenerate the section." ;;
      *)       log "WARNING: could not remove label '${REQUIRE_LABEL}' (HTTP ${code})." ;;
    esac
  fi
fi
