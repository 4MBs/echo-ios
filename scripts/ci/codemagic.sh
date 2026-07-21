#!/usr/bin/env bash
# Drive Codemagic builds from the command line: trigger a build, wait for it,
# and pull the artifacts (TestResults.xcresult, screenshots, IPA) down locally.
#
# This exists so changes can be verified on real macOS + iOS Simulator from a
# Linux machine, where Xcode does not exist and SwiftUI cannot be compiled.
#
# The API token is NEVER stored here or in the repo. Put it in:
#     ~/.config/codemagic/token      (chmod 600)
# or export CODEMAGIC_TOKEN in the environment.
#
# Usage:
#   scripts/ci/codemagic.sh apps                     # list apps + workflow ids
#   scripts/ci/codemagic.sh build <branch> [wf-id]   # start a build -> buildId
#   scripts/ci/codemagic.sh status <buildId>
#   scripts/ci/codemagic.sh wait <buildId>           # poll until finished
#   scripts/ci/codemagic.sh artifacts <buildId>      # list artifact names/urls
#   scripts/ci/codemagic.sh fetch <buildId> [dir]    # download all artifacts
#   scripts/ci/codemagic.sh run <branch> [wf-id]     # build + wait + fetch
set -euo pipefail

API="https://api.codemagic.io"
TOKEN_FILE="${CODEMAGIC_TOKEN_FILE:-$HOME/.config/codemagic/token}"

token() {
    if [ -n "${CODEMAGIC_TOKEN:-}" ]; then
        printf '%s' "$CODEMAGIC_TOKEN"
    elif [ -f "$TOKEN_FILE" ]; then
        tr -d '[:space:]' < "$TOKEN_FILE"
    else
        echo "error: no Codemagic token." >&2
        echo "  put it in $TOKEN_FILE (chmod 600), or export CODEMAGIC_TOKEN" >&2
        exit 1
    fi
}

# Resolve the token once, in the main shell — inside $(...) an `exit` would
# only kill the subshell and the script would carry on unauthenticated.
case "${1:-}" in
    ""|-h|--help|help) sed -n '2,25p' "$0"; exit 1 ;;
esac
TOKEN="$(token)"

api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "$method" -H "Content-Type: application/json"
                -H "x-auth-token: $TOKEN" "$API$path")
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}"
}

# APP_ID may be preset in the environment to skip the lookup
app_id() {
    if [ -n "${CODEMAGIC_APP_ID:-}" ]; then
        printf '%s' "$CODEMAGIC_APP_ID"
        return
    fi
    api GET /apps | jq -r '
        .applications[]
        | select(.appName | test("echo-ios|MossLive"; "i"))
        | ._id' | head -1
}

case "${1:-}" in
    apps)
        api GET /apps | jq -r '
            .applications[]
            | "\(._id)  \(.appName)",
              (.workflows // {} | to_entries[] | "    workflow: \(.key)  \(.value.name)")'
        ;;

    build)
        BRANCH="${2:?usage: build <branch> [workflowId]}"
        APP="$(app_id)"
        [ -n "$APP" ] || { echo "error: could not resolve appId; set CODEMAGIC_APP_ID" >&2; exit 1; }
        WF="${3:-ios-build}"
        RESP=$(api POST /builds "$(jq -nc \
            --arg a "$APP" --arg w "$WF" --arg b "$BRANCH" \
            '{appId:$a, workflowId:$w, branch:$b}')")
        echo "$RESP" | jq -r '.buildId // (. | tostring)'
        ;;

    status)
        ID="${2:?usage: status <buildId>}"
        api GET "/builds/$ID" | jq -r '.build.status // .status // (. | tostring)'
        ;;

    wait)
        ID="${2:?usage: wait <buildId>}"
        while :; do
            S=$(api GET "/builds/$ID" | jq -r '.build.status // .status // "unknown"')
            echo "[$(date +%H:%M:%S)] $S"
            case "$S" in
                finished|success|successful) exit 0 ;;
                failed|error|canceled|cancelled|timeout|skipped) exit 1 ;;
            esac
            sleep 20
        done
        ;;

    artifacts)
        ID="${2:?usage: artifacts <buildId>}"
        api GET "/builds/$ID" | jq -r '
            (.build.artefacts // .build.artifacts // [])[]
            | "\(.name)\t\(.url)"'
        ;;

    fetch)
        ID="${2:?usage: fetch <buildId> [dir]}"
        DEST="${3:-codemagic-artifacts/$ID}"
        mkdir -p "$DEST"
        api GET "/builds/$ID" | jq -r '
            (.build.artefacts // .build.artifacts // [])[]
            | "\(.name)\t\(.url)"' |
        while IFS=$'\t' read -r name url; do
            [ -n "$url" ] || continue
            echo "-> $name"
            curl -sS -L -H "x-auth-token: $TOKEN" -o "$DEST/$name" "$url"
        done
        echo "saved to $DEST"
        ls -la "$DEST"
        ;;

    run)
        BRANCH="${2:?usage: run <branch> [workflowId]}"
        ID=$("$0" build "$BRANCH" "${3:-ios-build}")
        echo "buildId: $ID"
        "$0" wait "$ID" || true
        "$0" fetch "$ID"
        ;;

    *)
        sed -n '2,25p' "$0"
        exit 1
        ;;
esac
