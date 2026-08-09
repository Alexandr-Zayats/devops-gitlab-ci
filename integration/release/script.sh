#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-}"                         
REPO_LIST="${REPO_LIST:-}"                     
CTO_USER_ID="${CTO_USER_ID:-22547557}"         
MAPPING_FILE="${MAPPING_FILE:-release/repos.yaml}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"

[[ -n "$VERSION" ]] || { echo "VERSION required"; exit 1; }
[[ -n "$REPO_LIST" ]] || { echo "REPO_LIST required"; exit 1; }
[[ -f "$MAPPING_FILE" ]] || { echo "Mapping file not found: $MAPPING_FILE"; exit 1; }

api() {
  local method=$1; shift
  local url=$1; shift
  local token_header
  if [[ -n "${GITLAB_TOKEN:-}" ]]; then
    token_header="PRIVATE-TOKEN: ${GITLAB_TOKEN}"
  else
    echo "No GITLAB_TOKEN available for API auth"; exit 1
  fi
  curl -sfS -X "$method" "https://${GITLAB_HOST}/api/v4/${url}" \
    -H "$token_header" \
    "$@"
}

normalize_list() { echo "$1" | tr ',' ' ' | xargs -n1; }

MAP_JSON=$(yq -o=json '.' "$MAPPING_FILE")

for repo in $(normalize_list "$REPO_LIST"); do
  echo "=== Repo ${repo} ==="
  project_id=$(echo "$MAP_JSON" | jq -r --arg r "$repo" '.repos[$r].id // empty')
  labels=$(echo "$MAP_JSON" | jq -r --arg r "$repo" '.repos[$r].labels // empty')
  assignee=$(echo "$MAP_JSON" | jq -r --arg r "$repo" '.repos[$r].assignee_id // empty')

  labels="${labels:-release,auto-created}"
  assignee="${assignee:-$CTO_USER_ID}"

  if [[ -z "$project_id" ]]; then
    echo "  ! No mapping for '$repo', skipping"
    continue
  fi

  rel_branch="release/${VERSION}"
  encoded_branch=$(printf '%s' "$rel_branch" | jq -s -R -r @uri)

  echo "  > Branch check"
  if api GET "projects/${project_id}/repository/branches/${encoded_branch}" >/dev/null 2>&1; then
    echo "  = Branch exists: $rel_branch"
  else
    echo "  + Creating branch $rel_branch from develop"
    api POST "projects/${project_id}/repository/branches" \
      -F "branch=$rel_branch" \
      -F "ref=develop"
  fi

  echo "  > Upserting .version"
  version_action="create"
  if api GET "projects/${project_id}/repository/files/$(printf '.version' | jq -s -R -r @uri)?ref=${encoded_branch}" >/dev/null 2>&1; then
    version_action="update"
  fi
  commit_payload=$(jq -n \
    --arg branch "$rel_branch" \
    --arg msg "chore: bump version to $VERSION" \
    --arg action "$version_action" \
    --arg content "$VERSION" \
    '{branch:$branch, commit_message:$msg, actions:[{action:$action, file_path:".version", content:$content}]}' \
  )
  printf '%s' "$commit_payload" | api POST "projects/${project_id}/repository/commits" \
    -H "Content-Type: application/json" \
    --data-binary @-

  create_mr() {
    local target=$1
    local title="Release ${VERSION} -> ${target}. Created - $(date +%Y-%m-%d)"
    if api GET "projects/${project_id}/merge_requests?source_branch=$rel_branch&target_branch=$target" | jq -e 'length > 0' >/dev/null; then
      echo "  = MR $rel_branch -> $target exists; skip"
      return
    fi
    echo "  + Creating MR -> $target"
    api POST "projects/${project_id}/merge_requests" \
      -F "source_branch=$rel_branch" \
      -F "target_branch=$target" \
      -F "title=$title" \
      -F "labels=$labels" \
      -F "assignee_id=$assignee"
  }

  create_mr "main"
  create_mr "develop"
done
