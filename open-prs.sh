#!/usr/bin/env bash
# Opens the upstream PRs from malaiwah/hermes-conduit against kaishi00/hermes-conduit.
# Run from the root of this branch's checkout (bodies/ must be next to this script).
set -e
cd "$(dirname "$0")"

REPO=kaishi00/hermes-conduit
PREFIX=claude/project-thread-a5adb1-

open_pr() {
  local short="$1" title="$2"
  local head="${PREFIX}${short}"
  echo "==> ${short}: ${title}"
  local existing
  existing=$(gh pr list --repo "$REPO" --head "$head" --json number -q length)
  if [ "$existing" != "0" ]; then
    echo "    already open for ${head}, skipping"
    return 0
  fi
  gh pr create --repo "$REPO" --base main --head "malaiwah:${head}" \
    --title "$title" --body-file "bodies/${short}.md"
}

open_pr 4007-recovery "A cold launch recovers from a listed saved session the gateway reports missing"
open_pr approval-digest "An approval answers only the command its card showed, every line of it reachable and every character visible"
open_pr approval-request-id "An approval card without a request id answers the queued request it shows, not the oldest"
open_pr audio-queue "Ending a voice conversation no longer blocks the main thread on audio session deactivation"
open_pr a11y-guard "The clarify send buttons and the Kanban search clear button have spoken names"
open_pr accent-palette "Your own messages stay readable in every accent colour, dark mode included"
open_pr relay-build-setting "A build can register push under its own bundle ID and name its default relay"
open_pr xctest-deadline "A lane's finalize deadline starts when XCTest reports the test session ended"
