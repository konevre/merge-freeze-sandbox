#!/usr/bin/env bash
# Sets the `merge-freeze` commit status on every open PR into dev and staging, from live PR state:
#   dev     is frozen while an open, non-draft dev -> staging PR exists
#   staging is frozen while an open, non-draft staging -> master PR exists
# MERGE_FREEZE_DRY_RUN=true prints the status changes instead of posting them.
# no set -e: one failed POST must not stop the other PRs; the exit code reports it at the end.
set -uo pipefail

: "${GH_REPO:?GH_REPO is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${MERGE_FREEZE_DRY_RUN:=false}"

log() { printf '%s\n' "$*" >&2; }

# shellcheck disable=SC2016
QUERY='query($owner: String!, $repo: String!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequests(states: OPEN, first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number url isDraft isCrossRepository baseRefName headRefName headRefOid
        autoMergeRequest { enabledAt }
        commits(last: 1) { nodes { commit { oid status { contexts { context state description } } } } }
      }
    }
  }
}'

# Input: the GraphQL pages (slurped). Output: {open, dev, staging, posts[]}; posts are the statuses
# that differ from what is already on the head commit, pending first, auto-merge PRs first among them.
# A status lives on a commit, so PRs sharing a head SHA are folded into one, pending winning.
# shellcheck disable=SC2016
PLAN_JQ='
if any(.[]; has("errors")) then error("GraphQL returned errors") else . end
| [ .[].data.repository.pullRequests.nodes[] ] as $prs
| [ $prs[] | select(.isDraft == false and .isCrossRepository == false) ] as $ready
| {
    dev:     ([ $ready[] | select(.headRefName == "dev" and .baseRefName == "staging") ] | sort_by(.number) | first),
    staging: ([ $ready[] | select(.headRefName == "staging" and .baseRefName == "master") ] | sort_by(.number) | first)
  } as $release
| ( [ $prs[]
      | select(.baseRefName == "dev" or .baseRefName == "staging")
      | . as $pr
      | $release[$pr.baseRefName] as $rel
      | {
          number: $pr.number,
          sha: $pr.headRefOid,
          auto: ($pr.autoMergeRequest != null),
          current: ([ $pr.commits.nodes[0].commit | select(.oid == $pr.headRefOid) | (.status.contexts // [])[] | select(.context == "merge-freeze") ] | first),
          want: (
            if $rel == null or ($pr.isCrossRepository == false and ($pr.headRefName | startswith("german-ai/ladder-")))
            then { state: "success", description: "\($pr.baseRefName) is not frozen", target_url: null }
            else { state: "pending", description: "\($pr.baseRefName) is frozen by release PR #\($rel.number) (\($rel.headRefName)→\($rel.baseRefName))", target_url: $rel.url }
            end
          )
        }
    ]
    | group_by(.sha)
    | map(
        sort_by(.number) as $group
        | ([ $group[] | select(.want.state == "pending") ] | first) as $pending
        | ($pending // $group[0]) as $pick
        | {
            sha: $pick.sha,
            state: $pick.want.state,
            description: $pick.want.description,
            target_url: $pick.want.target_url,
            auto: ($group | any(.auto)),
            pr: $pick.number,
            current: ([ $group[].current | select(. != null) ] | first)
          }
      )
    | map(select(.current == null or (.current.state | ascii_downcase) != .state or .current.description != .description))
    | sort_by([ (if .state == "pending" then 0 else 1 end), (if .auto then 0 else 1 end), .pr ])
  ) as $posts
| { open: ($prs | length), dev: $release.dev.number, staging: $release.staging.number, posts: $posts }
'

main() {
  local pages plan posts=0 failed=0 sha state desc url
  local -a args

  if ! pages="$(gh api graphql --paginate -f query="$QUERY" -f owner="${GH_REPO%/*}" -f repo="${GH_REPO#*/}")"; then
    log "::error::could not read the open pull requests; nothing posted"
    exit 1
  fi
  if ! plan="$(printf '%s' "$pages" | jq -c -s "$PLAN_JQ")"; then
    log "::error::could not compute the freeze plan from the GraphQL response; nothing posted"
    exit 1
  fi
  log "$(printf '%s' "$plan" | jq -r '"open PRs: \(.open); dev frozen by: \(.dev // "-"); staging frozen by: \(.staging // "-"); status changes: \(.posts | length)"')"

  while IFS=$'\t' read -r sha state desc url; do
    [ -n "$sha" ] || continue
    if [ "$MERGE_FREEZE_DRY_RUN" = true ]; then
      log "dry-run: ${sha:0:10} ${state} ${desc}"
      posts=$((posts + 1))
      continue
    fi
    args=(-f "state=${state}" -f "context=merge-freeze" -f "description=${desc}")
    [ -n "$url" ] && args+=(-f "target_url=${url}")
    if gh api --method POST "repos/${GH_REPO}/statuses/${sha}" "${args[@]}" > /dev/null; then
      log "posted: ${sha:0:10} ${state} ${desc}"
      posts=$((posts + 1))
    else
      log "::error::could not post ${state} on ${sha:0:10}: ${desc}"
      failed=$((failed + 1))
    fi
  done < <(printf '%s' "$plan" | jq -r '.posts[] | [.sha, .state, .description, (.target_url // "")] | @tsv')

  log "status changes: ${posts} done, ${failed} failed"
  [ "$failed" -eq 0 ]
}

main "$@"
