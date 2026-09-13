#!/usr/bin/env bash
# captain-input-linux-capture.sh
#
# Reference script the captain installs and runs on their OWN Linux/Wayland
# laptop. Firstmate never runs, deploys, or controls this script - it is not
# part of the fleet, it is the client half of the captain-input screenshot-drop
# channel described in docs/configuration.md ("Captain input"), mirroring
# captain-input-windows-capture.ahk's role for a Wayland/Hyprland setup instead
# of Windows.
#
# What it does: reads whatever image is currently on the Wayland clipboard
# (via wl-clipboard's wl-paste), uploads it to the firstmate host at a temp
# name, publishes it under its final name with an atomic remote rename
# (mirroring the same temp-then-rename discipline the host side already uses -
# see bin/fm-captain-input-watch.sh's header), then writes the paired JSON
# envelope the same atomic way.
#
# Trigger model: unlike the Windows script (a persistent clipboard-change
# listener that fires on every image copy), this script is meant to be called
# once per deliberate keypress - see the accompanying design at
# data/ssh-multimodal-input-plan-001/report.md and the Hyprland dispatcher
# pattern that scopes a SUPER+V keybind to one specific SSH terminal window,
# falling back to the normal paste action everywhere else. This script itself
# doesn't care how it was invoked - it sends a supported image from the
# clipboard when one is present and otherwise exits without delivery.
#
# Concurrency: multiple instances of this script can run at once (e.g. two
# different SSH windows triggered close together) without colliding or
# blocking each other - every temp/remote filename is namespaced by a unique
# per-invocation id (timestamp + pid + random), so there is no shared lock to
# contend on and no reentrancy guard needed (unlike the Windows script, whose
# mutex-style guard exists to solve a different problem: Windows' clipboard-
# change event firing twice for one screenshot tool - a hazard that doesn't
# apply to a script invoked once per keypress).
#
# Requirements on this Linux machine: wl-clipboard (wl-paste, for a Wayland
# session - Hyprland ships one by default), jq, an SSH client with scp on
# PATH, and SSH key auth already set up to the firstmate host (this script
# never prompts for a password - SSH auth to that account IS the
# authorization boundary for this channel, see docs/configuration.md
# "Captain input"). notify-send (libnotify) is optional; its absence only
# means silent operation instead of desktop notifications.
#
# ---- fill these in for your setup ------------------------------------------
FM_HOST="REPLACE_ME_host_or_alias"      # e.g. "myserver" (an ~/.ssh/config Host entry is easiest)
FM_USER="REPLACE_ME_ssh_user"           # the account firstmate runs as on that host
FM_REMOTE_DROP_DIR="REPLACE_ME_/absolute/path/to/firstmate/state/captain-drop"
# -----------------------------------------------------------------------------

set -u

notify() {
    # $1=title $2=message; never let a missing notify-send break the script.
    command -v notify-send >/dev/null 2>&1 && notify-send "$1" "$2" 2>/dev/null || true
}

fail() {
    notify "Captain input" "Screenshot send failed: $1"
    printf 'captain-input-linux-capture.sh: %s\n' "$1" >&2
    exit 1
}

command -v wl-paste >/dev/null 2>&1 || fail "wl-paste not found (install wl-clipboard)"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v scp >/dev/null 2>&1 || fail "scp not found"
command -v ssh >/dev/null 2>&1 || fail "ssh not found"

# Pick an available supported image MIME type off the clipboard, preferring
# PNG. The Hyprland dispatcher can invoke this script for every keypress, so
# it performs the clipboard check itself and is also safe to invoke directly.
types=$(wl-paste --list-types 2>/dev/null) || fail "could not list clipboard types"
mime=
has_unsupported_image=0
while IFS= read -r offered_mime; do
    case "$offered_mime" in
        image/png) mime=image/png; break ;;
        image/jpeg) [ -n "$mime" ] || mime=image/jpeg ;;
        image/*) has_unsupported_image=1 ;;
    esac
done <<< "$types"
# Silent, non-error exit when there's no image: this script is now invoked on
# every SUPER+V press inside the captain-ssh window regardless of clipboard
# content (see the Hyprland dispatcher's design note on avoiding a
# synchronous clipboard check inside its own keypress handler), so the plain-
# text-paste case is the common path here, not a failure.
[ -n "$mime" ] || {
    [ "$has_unsupported_image" -eq 0 ] && exit 0
    fail "clipboard image type is unsupported"
}
case "$mime" in
    image/png) ext=png ;;
    image/jpeg) ext=jpg ;;
esac

# Unique per invocation, not just per second - see the concurrency note
# above. Two captures fired from two different windows in the same second
# must never collide on a filename.
id="shot-$(date +%s)-$$-${RANDOM}"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/captain-input.XXXXXX") || fail "cannot create temp directory"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT

local_payload="$TMP_DIR/$id.$ext"
local_envelope="$TMP_DIR/$id.json"

wl-paste -t "$mime" > "$local_payload" 2>/dev/null || fail "could not read clipboard image"
[ -s "$local_payload" ] || fail "clipboard image was empty"

remote_tmp_payload="$FM_REMOTE_DROP_DIR/.tmp-$id.$ext"
remote_final_payload="$FM_REMOTE_DROP_DIR/$id.$ext"
remote_tmp_envelope="$FM_REMOTE_DROP_DIR/.tmp-$id.json"
remote_final_envelope="$FM_REMOTE_DROP_DIR/$id.json"

# 1. Upload the payload to a temp name, then atomically publish it with a
#    remote rename - never let the watcher see a partially-written file.
scp -q "$local_payload" "$FM_USER@$FM_HOST:$remote_tmp_payload" \
    || fail "payload upload failed (scp)"
ssh -n -T "$FM_USER@$FM_HOST" mv "$remote_tmp_payload" "$remote_final_payload" \
    || fail "payload publish failed (ssh mv)"

# 2. Write the paired envelope last, the same atomic way - the envelope
#    landing under its final name is the "this drop is complete" signal the
#    watch script (bin/fm-captain-input-watch.sh) waits for.
dropped_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg id "$id" --arg path "$remote_final_payload" --arg dropped_at "$dropped_at" \
    '{id: $id, type: "screenshot", path: $path, caption: "", dropped_at: $dropped_at}' \
    > "$local_envelope" || fail "could not build envelope"

scp -q "$local_envelope" "$FM_USER@$FM_HOST:$remote_tmp_envelope" \
    || fail "envelope upload failed (scp)"
ssh -n -T "$FM_USER@$FM_HOST" mv "$remote_tmp_envelope" "$remote_final_envelope" \
    || fail "envelope publish failed (ssh mv)"

notify "Captain input" "Screenshot sent to firstmate ($id)"
