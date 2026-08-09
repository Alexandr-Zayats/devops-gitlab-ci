#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-}"
REPO_LIST="${REPO_LIST:-}"
MAPPING_FILE="${MAPPING_FILE:-release/repos.yaml}"
GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
CURRENT_RELEASE_FILE="${CURRENT_RELEASE_FILE:-release/current_release.yaml}"

[[ -n "$VERSION" ]] || { echo "VERSION required"; exit 1; }
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
  rel_branch="release/${VERSION}"
  encoded_branch=$(printf '%s' "$rel_branch" | jq -s -R -r @uri)
  if api GET "projects/${project_id}/repository/branches/${encoded_branch}" >/dev/null 2>&1; then
    echo "  = [$repo] branch exists: $rel_branch"
    found=true
  else
    echo "  ! [$repo] missing branch: $rel_branch"
    missing+=("$repo")
  fi
done

if [[ "$found" != true ]]; then
  printf "No repositories contain branch release/%s. Missing: [%s]\n" "$VERSION" "$(IFS=','; echo "${missing[*]-}")"
  exit 1
fi

echo "Validation passed. Updating ${CURRENT_RELEASE_FILE}"
updated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
updated_by="${GITLAB_USER_EMAIL:-ci-job}"
cat > "$CURRENT_RELEASE_FILE" <<EOF
current_release: "$VERSION"
updated_at: "$updated_at"
updated_by: "$updated_by"
EOF

git status --short
if ! git diff --quiet -- "$CURRENT_RELEASE_FILE"; then
  git config user.name "${GITLAB_USER_NAME:-devops}"
  git config user.email "${GITLAB_USER_EMAIL:-devops@example-org.com}"
  git add "$CURRENT_RELEASE_FILE"
  git commit -m "chore: set current_release to ${VERSION}"
  git push origin "HEAD:${CI_COMMIT_REF_NAME}"
  echo "current_release set to ${VERSION} and pushed."
else
  echo "No changes to commit."
fi
