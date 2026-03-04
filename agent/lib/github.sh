#!/usr/bin/env bash
# =============================================================================
# Marvin — GitHub API Library
# =============================================================================
# Shared functions for interacting with the GitHub API.
# All operations are authenticated via GITHUB_TOKEN and commits are GPG-signed.
#
# Usage: source this file from agent scripts
#   source "$(dirname "$0")/lib/github.sh"
# =============================================================================

# Configuration
GITHUB_REPO="${GITHUB_REPO:-INFO-WEB-s-r-o/Marvin}"
GITHUB_API="https://api.github.com"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Load token from .env if not set
if [[ -z "$GITHUB_TOKEN" && -f "${MARVIN_DIR}/.env" ]]; then
    GITHUB_TOKEN=$(grep -oP '^GITHUB_TOKEN=\K.+' "${MARVIN_DIR}/.env" 2>/dev/null || echo "")
fi

# Also check /etc/environment
if [[ -z "$GITHUB_TOKEN" ]]; then
    GITHUB_TOKEN=$(grep -oP '^GITHUB_TOKEN=\K.+' /etc/environment 2>/dev/null || echo "")
fi

# ─── Validation ──────────────────────────────────────────────────────────────

github_check_token() {
    if [[ -z "$GITHUB_TOKEN" ]]; then
        marvin_log "ERROR" "GITHUB_TOKEN not set. Cannot interact with GitHub."
        return 1
    fi

    # Verify token works
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API}/user")

    if [[ "$response" != "200" ]]; then
        marvin_log "ERROR" "GitHub token validation failed (HTTP ${response})"
        return 1
    fi

    return 0
}

# ─── Core API call ───────────────────────────────────────────────────────────

# Generic GitHub API call with retry
# Usage: github_api METHOD endpoint [json_body]
github_api() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"
    local url="${GITHUB_API}${endpoint}"
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        local curl_args=(
            -s
            -X "$method"
            -H "Authorization: token ${GITHUB_TOKEN}"
            -H "Accept: application/vnd.github.v3+json"
            -H "User-Agent: Marvin-AI-Agent/1.0"
            -w "\n%{http_code}"
        )

        if [[ -n "$body" ]]; then
            curl_args+=(-H "Content-Type: application/json" -d "$body")
        fi

        local raw_response
        raw_response=$(curl "${curl_args[@]}" "$url" 2>/dev/null)

        local http_code
        http_code=$(echo "$raw_response" | tail -1)
        local response_body
        response_body=$(echo "$raw_response" | sed '$d')

        # Rate limit handling
        if [[ "$http_code" == "403" ]] && echo "$response_body" | jq -e '.message | test("rate limit")' &>/dev/null; then
            local reset_time
            reset_time=$(echo "$response_body" | jq -r '.message' 2>/dev/null || echo "unknown")
            marvin_log "WARN" "GitHub rate limit hit. Waiting 60s... (${reset_time})"
            sleep 60
            retry=$((retry + 1))
            continue
        fi

        # Success range (2xx)
        if [[ "$http_code" =~ ^2 ]]; then
            echo "$response_body"
            return 0
        fi

        # Client errors (4xx) — don't retry
        if [[ "$http_code" =~ ^4 ]]; then
            marvin_log "ERROR" "GitHub API ${method} ${endpoint}: HTTP ${http_code}"
            marvin_log "ERROR" "Response: $(echo "$response_body" | jq -r '.message // .' 2>/dev/null | head -5)"
            echo "$response_body"
            return 1
        fi

        # Server errors (5xx) — retry
        marvin_log "WARN" "GitHub API ${method} ${endpoint}: HTTP ${http_code}, retry ${retry}/${max_retries}"
        sleep $((5 * (retry + 1)))
        retry=$((retry + 1))
    done

    marvin_log "ERROR" "GitHub API ${method} ${endpoint}: failed after ${max_retries} retries"
    return 1
}

# ─── Issues ──────────────────────────────────────────────────────────────────

# Create a GitHub issue
# Usage: github_create_issue "title" "body" "label1,label2"
github_create_issue() {
    local title="$1"
    local body="$2"
    local labels="${3:-}"

    local labels_json="[]"
    if [[ -n "$labels" ]]; then
        labels_json=$(echo "$labels" | tr ',' '\n' | jq -R -s 'split("\n") | map(select(. != ""))')
    fi

    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --argjson labels "$labels_json" \
        '{title: $title, body: $body, labels: $labels}')

    local response
    response=$(github_api POST "/repos/${GITHUB_REPO}/issues" "$payload")
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        local issue_number
        issue_number=$(echo "$response" | jq -r '.number')
        local issue_url
        issue_url=$(echo "$response" | jq -r '.html_url')
        marvin_log "INFO" "Created issue #${issue_number}: ${issue_url}"
        echo "$response"
    fi

    return $exit_code
}

# Comment on an existing issue
# Usage: github_comment_issue issue_number "comment body"
github_comment_issue() {
    local issue_number="$1"
    local body="$2"

    local payload
    payload=$(jq -n --arg body "$body" '{body: $body}')

    github_api POST "/repos/${GITHUB_REPO}/issues/${issue_number}/comments" "$payload"
}

# Close an issue
# Usage: github_close_issue issue_number
github_close_issue() {
    local issue_number="$1"
    github_api PATCH "/repos/${GITHUB_REPO}/issues/${issue_number}" '{"state":"closed"}'
}

# List open issues
# Usage: github_list_issues [labels] [limit]
github_list_issues() {
    local labels="${1:-}"
    local limit="${2:-30}"
    local query="per_page=${limit}&state=open"
    [[ -n "$labels" ]] && query+="&labels=${labels}"

    github_api GET "/repos/${GITHUB_REPO}/issues?${query}"
}

# ─── Pull Requests ───────────────────────────────────────────────────────────

# Push a branch and create a PR
# Usage: github_create_pr "branch_name" "title" "body" [base_branch]
github_create_pr() {
    local branch="$1"
    local title="$2"
    local body="$3"
    local base="${4:-main}"

    # Push the branch to GitHub
    if ! github_push_branch "$branch"; then
        marvin_log "ERROR" "Failed to push branch ${branch}"
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --arg head "$branch" \
        --arg base "$base" \
        '{title: $title, body: $body, head: $head, base: $base}')

    local response
    response=$(github_api POST "/repos/${GITHUB_REPO}/pulls" "$payload")
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        local pr_number
        pr_number=$(echo "$response" | jq -r '.number')
        local pr_url
        pr_url=$(echo "$response" | jq -r '.html_url')
        marvin_log "INFO" "Created PR #${pr_number}: ${pr_url}"
        echo "$response"
    fi

    return $exit_code
}

# List open pull requests
# Usage: github_list_prs [limit]
github_list_prs() {
    local limit="${1:-10}"
    github_api GET "/repos/${GITHUB_REPO}/pulls?per_page=${limit}&state=open"
}

# Merge a pull request
# Usage: github_merge_pr pr_number [commit_message]
github_merge_pr() {
    local pr_number="$1"
    local commit_message="${2:-}"

    local payload
    payload=$(jq -n \
        --arg msg "$commit_message" \
        '{merge_method: "merge", commit_message: $msg}')

    local response
    response=$(github_api PUT "/repos/${GITHUB_REPO}/pulls/${pr_number}/merge" "$payload")
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        marvin_log "INFO" "PR #${pr_number} merged successfully"
    else
        marvin_log "WARN" "Could not auto-merge PR #${pr_number} — may require manual review"
    fi

    return $exit_code
}

# ─── Git Operations (GPG-signed) ────────────────────────────────────────────

# Configure git remote for GitHub
github_setup_remote() {
    cd "$MARVIN_DIR"

    # Set remote (use token for auth)
    local remote_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

    if git remote get-url origin &>/dev/null; then
        git remote set-url origin "$remote_url"
    else
        git remote add origin "$remote_url"
    fi

    marvin_log "INFO" "GitHub remote configured for ${GITHUB_REPO}"
}

# Push a branch to GitHub (GPG-signed commits)
github_push_branch() {
    local branch="$1"
    cd "$MARVIN_DIR"

    github_setup_remote

    # Ensure we're on the right branch
    git checkout "$branch" 2>/dev/null || git checkout -b "$branch"

    # Push with force-with-lease (safe force push for rebased branches)
    if git push --force-with-lease origin "$branch" 2>&1; then
        marvin_log "INFO" "Pushed branch ${branch} to GitHub"
        return 0
    else
        marvin_log "ERROR" "Failed to push branch ${branch}"
        return 1
    fi
}

# Push main branch to GitHub
github_push_main() {
    cd "$MARVIN_DIR"
    github_setup_remote
    git push origin main 2>&1 || {
        marvin_log "ERROR" "Failed to push main to GitHub"
        return 1
    }
    marvin_log "INFO" "Pushed main branch to GitHub"
}

# Safe stash pop — recovers from conflicts instead of leaving markers
# If pop produces conflicts, discard conflicted merge and drop the stash
_safe_stash_pop() {
    if ! git stash pop --quiet 2>/dev/null; then
        # Stash pop failed (likely conflicts) — check for conflict markers
        if git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            marvin_log "WARN" "Stash pop produced conflicts — discarding stash (data regenerates via cron)"
            git checkout -- . 2>/dev/null || true
            git stash drop --quiet 2>/dev/null || true
        fi
    fi
}

# Create a signed commit on a new branch
# Usage: github_signed_commit "branch" "message" [files...]
github_signed_commit() {
    local branch="$1"
    local message="$2"
    shift 2
    local files=("$@")

    cd "$MARVIN_DIR"

    # Stash any current changes
    git stash --quiet 2>/dev/null || true

    # Create branch from main
    git checkout main 2>/dev/null || true
    git checkout -b "$branch" 2>/dev/null || git checkout "$branch"

    # Stage files
    if [[ ${#files[@]} -gt 0 ]]; then
        for f in "${files[@]}"; do
            git add "$f"
        done
    else
        git add -A
    fi

    # Create GPG-signed commit
    if git diff --cached --quiet 2>/dev/null; then
        marvin_log "WARN" "No changes to commit on branch ${branch}"
        git checkout main 2>/dev/null || true
        _safe_stash_pop
        return 1
    fi

    # Commit (git is already configured to GPG-sign via setup-gpg.sh)
    git commit -S -m "$message" 2>&1 || {
        marvin_log "ERROR" "GPG-signed commit failed"
        git checkout main 2>/dev/null || true
        _safe_stash_pop
        return 1
    }

    marvin_log "INFO" "Created GPG-signed commit on ${branch}: ${message}"

    # Return to main, keep the branch
    git checkout main 2>/dev/null || true
    _safe_stash_pop
    return 0
}

# ─── GPG Key Upload to GitHub ───────────────────────────────────────────────

# Upload Marvin's GPG public key to GitHub
github_upload_gpg_key() {
    local key_file="${MARVIN_DIR}/data/comms/marvin-gpg-public.asc"

    if [[ ! -f "$key_file" ]]; then
        marvin_log "ERROR" "GPG public key not found at ${key_file}"
        return 1
    fi

    local armored_key
    armored_key=$(cat "$key_file")

    local payload
    payload=$(jq -n --arg key "$armored_key" '{armored_key: $key}')

    local response
    response=$(github_api POST "/user/gpg_keys" "$payload")
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        local key_id
        key_id=$(echo "$response" | jq -r '.key_id')
        marvin_log "INFO" "GPG key uploaded to GitHub: ${key_id}"
    elif echo "$response" | jq -e '.errors[]?.message | test("already been taken")' &>/dev/null; then
        marvin_log "INFO" "GPG key already exists on GitHub"
        return 0
    fi

    return $exit_code
}

# ─── Utility ─────────────────────────────────────────────────────────────────

# GPG-sign an arbitrary message (for non-git proof of authenticity)
# Usage: marvin_sign "message" → outputs detached signature
marvin_sign() {
    local message="$1"
    local key_id
    key_id=$(marvin_gpg_key_id 2>/dev/null || echo "")
    local gpg_args=(--homedir /home/marvin/.gnupg --armor --detach-sign)
    if [[ -n "$key_id" ]]; then
        gpg_args+=(--local-user "$key_id")
    fi
    echo "$message" | gpg "${gpg_args[@]}" 2>/dev/null
}

# Verify a GPG signature
# Usage: marvin_verify "message" "signature"
marvin_verify() {
    local message="$1"
    local signature="$2"
    echo "$signature" | gpg --verify - <(echo "$message") 2>&1
}

# Get Marvin's GPG key ID
marvin_gpg_key_id() {
    local gpg_info="${MARVIN_DIR}/data/comms/gpg-info.json"
    if [[ -f "$gpg_info" ]]; then
        jq -r '.key_id' "$gpg_info"
    else
        # Fallback: read key ID from gpg directly (use marvin's homedir since cron runs as root)
        gpg --homedir /home/marvin/.gnupg --list-keys --keyid-format long 2>/dev/null | grep -oP '(?<=/)[A-Fa-f0-9]{8,}' | head -1
    fi
}

# Sign a JSON payload and add signature field
# Usage: marvin_sign_json '{"data":"value"}' → '{"data":"value","gpg_signature":"..."}'
marvin_sign_json() {
    local json="$1"
    local canonical
    canonical=$(echo "$json" | jq -cS '.')  # Canonical form for deterministic signing
    local signature
    signature=$(marvin_sign "$canonical")

    echo "$json" | jq --arg sig "$signature" --arg kid "$(marvin_gpg_key_id)" \
        '. + {gpg_signature: $sig, gpg_key_id: $kid, signed_at: (now | todate)}'
}
