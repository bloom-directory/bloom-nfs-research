#!/usr/bin/env bash
# One-shot orchestrator for the pm#38 macOS kill-gate. Run this locally.
# Does everything except the firewall toggle (which it walks you through inline).
#
# Why the firewall toggle is manual: the GitHub-hosted macOS runner is on a
# rotating public IP and must reach cocoroco on tcp+udp 88 + tcp 2049 to mount.
# The script keeps the open window to just the run, and supervises the close.
#
# Prereqs (auto-checked): gh authed; SSH key to cocoroco; sudo on cocoroco.
set -uo pipefail

REPO="bloom-directory/bloom-nfs-research"
WORKFLOW="macos-killgate.yml"
HOST="cocoroco"
die() { echo "ERROR: $*" >&2; exit 1; }

echo ">>> checking prerequisites"
command -v gh >/dev/null || die "gh CLI not installed"
gh auth status >/dev/null 2>&1 || die "gh not authed (run: gh auth login)"
gh repo view "$REPO" >/dev/null 2>&1 || die "repo $REPO not accessible"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" true 2>/dev/null || die "can't SSH to $HOST (key auth)"

echo
echo ">>> step 1/4: set WS_WS1_PASS secret from cocoroco (prompts for sudo on $HOST)"
ssh -t "$HOST" 'sudo install -m 644 -o cocoroco -g cocoroco /root/ws-secrets/peer.env /tmp/peer.env' || die "staging peer.env failed"
ssh -o BatchMode=yes "$HOST" 'grep "^WS_ws1_PASS=" /tmp/peer.env | cut -d= -f2- | tr -d "\n"' \
  | gh secret set WS_WS1_PASS --repo "$REPO" || die "setting secret failed"
ssh -o BatchMode=yes "$HOST" 'rm -f /tmp/peer.env'
echo "    secret set."

# Supervised firewall close — runs on normal exit AND Ctrl-C, so it can't be forgotten.
close_fw() {
  echo
  echo ">>> CLOSE cocoroco's firewall now: remove the 0.0.0.0/0 rule on tcp+udp 88 + tcp 2049."
  printf "    Press Enter once confirmed closed: "
  read -r _
  echo "    done."
}
trap close_fw EXIT

echo
echo ">>> step 2/4: OPEN cocoroco's firewall for the macOS runner"
echo "    In your cloud console add inbound: tcp+udp 88 + tcp 2049, source 0.0.0.0/0."
echo "    (Bounded: export is krb5p-only + 24-char random pw; window is just this run.)"
printf "    Press Enter once the rule is added: "
read -r _

echo
echo ">>> step 3/4: trigger the macOS workflow (macos-26 Tahoe) and stream it"
gh workflow run "$WORKFLOW" --repo "$REPO" || die "trigger failed"
sleep 6
RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')"
[ -n "$RUN_ID" ] || die "couldn't find the run ID — check $REPO/actions"
echo "    run: https://github.com/$REPO/actions/runs/$RUN_ID"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status || echo "    (run ended; status shown above — a failed run is still valid evidence)"

echo
echo ">>> step 4/4: download the transcript"
DIR="./evidence/macos-run-$RUN_ID"
gh run download "$RUN_ID" --repo "$REPO" -n killgate-transcript -D "$DIR" 2>/dev/null \
  && echo "    transcript saved: $DIR/killgate.txt" \
  || echo "    (artifact not downloaded — grab it from the run URL above)"

echo
echo ">>> open the transcript for the macOS verdict:"
echo "    less $DIR/killgate.txt"
echo
echo "    The firewall-close prompt follows on exit."
