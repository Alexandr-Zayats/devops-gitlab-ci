#!/usr/bin/env bash
set -euo pipefail

HOTFIX_REF="${HOTFIX_REF:-}"
REPO_LIST="${REPO_LIST:-}"
MAPPING_FILE="${MAPPING_FILE:-release/repos.yaml}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
HOTFIX_FILE="${HOTFIX_FILE:-release/hotfix_ref.yaml}"

[[ -n "$HOTFIX_REF" ]] || { echo "HOTFIX_REF required"; exit 1; }
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

if [[ -n "$REPO_LIST" ]]; then
  repos=$(normalize_list "$REPO_LIST")
else
  repos=$(echo "$MAP_JSON" | jq -r '.repos | keys[]')
fi

found=false
missing=()

for repo in $repos; do
  project_id=$(echo "$MAP_JSON" | jq -r --arg r "$repo" '.repos[$r].id // empty')
  if [[ -z "$project_id" ]]; then
    echo "  ! No mapping for '$repo', skipping"
    continue
  fi
  hot_branch="hotfix/${HOTFIX_REF}"
  encoded_branch=$(printf '%s' "$hot_branch" | jq -s -R -r @uri)
  if api GET "projects/${project_id}/repository/branches/${encoded_branch}" >/dev/null 2>&1; then
    echo "  = [$repo] branch exists: $hot_branch"
    found=true
  else
    echo "  ! [$repo] missing branch: $hot_branch"
    missing+=("$repo")
  fi
done

if [[ "$found" != true ]]; then
  printf "No repositories contain branch hotfix/%s. Missing: [%s]\n" "$HOTFIX_REF" "$(IFS=','; echo "${missing[*]-}")"
  exit 1
fi

echo "Validation passed. Updating ${HOTFIX_FILE}"
updated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
updated_by="${GITLAB_USER_EMAIL:-ci-job}"
cat > "$HOTFIX_FILE" <<EOF
hotfix_ref: "$HOTFIX_REF"
updated_at: "$updated_at"
updated_by: "$updated_by"
EOF

git status --short
if ! git diff --quiet -- "$HOTFIX_FILE"; then
  git config user.name "${GITLAB_USER_NAME:-ci}"
  git config user.email "${GITLAB_USER_EMAIL:-devops@example-org.com}"
  git add "$HOTFIX_FILE"
  git commit -m "chore: set hotfix_ref to ${HOTFIX_REF}"
  git push origin "HEAD:${CI_COMMIT_REF_NAME}"
  echo "hotfix_ref set to ${HOTFIX_REF} and pushed."
else
  echo "No changes to commit."
fi
