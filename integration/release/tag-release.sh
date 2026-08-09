#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-}"
REPO_LIST="${REPO_LIST:-}"
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

missing=()
declare -A project_ids

for repo in $(normalize_list "$REPO_LIST"); do
  project_id=$(echo "$MAP_JSON" | jq -r --arg r "$repo" '.repos[$r].id // empty')
  if [[ -z "$project_id" ]]; then
    echo "  ! No mapping for '$repo', treating as missing"
    missing+=("$repo")
    continue
  fi
  project_ids["$repo"]="$project_id"

  rel_branch="release/${VERSION}"
  encoded_branch=$(printf '%s' "$rel_branch" | jq -s -R -r @uri)

  if api GET "projects/${project_id}/repository/branches/${encoded_branch}" >/dev/null 2>&1; then
    echo "  = [$repo] branch exists: $rel_branch"
  else
    echo "  ! [$repo] missing branch: $rel_branch"
    missing+=("$repo")
  fi
done

if ((${#missing[@]} > 0)); then
  printf "Missing release/%s in: [%s]\n" "$VERSION" "$(IFS=','; echo "${missing[*]}")"
  exit 1
fi

TAG="${VERSION}.$(date -u +%Y%m%d%H%M%S)"
echo "Tag to create: $TAG"

for repo in $(normalize_list "$REPO_LIST"); do
  project_id="${project_ids[$repo]}"
  rel_branch="release/${VERSION}"
  echo "  + [$repo] creating tag $TAG at $rel_branch"
  api POST "projects/${project_id}/repository/tags" \
    -F "tag_name=$TAG" \
    -F "ref=$rel_branch"
done

echo "Created tag $TAG for repos: $REPO_LIST"
