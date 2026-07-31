#!/usr/bin/env bash
# Watch/enqueue logic for the captain-input screenshot-drop channel (Phase 1).
#
# Not run directly by the watcher: bin/fm-captain-input-enable.sh writes a
# trampoline to state/captain-input.check.sh that execs this trusted repository
# script, then binds the trampoline's bytes with bin/fm-check-register.sh. This
# is the same trust split X mode uses (a byte-bound state/ shim execs a real
# script the watcher never hashes because it is already git-controlled) applied
# through the generic custom-check mechanism instead of a special-cased shim.
#
# On each invocation: scans state/captain-drop/*.json for envelopes
# ({id, type, path, caption, dropped_at}), skips any envelope or payload file
# younger than a short quiet period (still-growing / mid-transfer), and for
# every complete one enqueues a wake-queue record keyed "captain-input:<id>"
# (so distinct drops never collapse under the queue's per-key drain dedup, even
# across multiple polls before firstmate drains) and moves the envelope plus
# its payload into state/captain-drop/.consumed/ so a re-scan never reports the
# same drop twice. Also prints one summary line when at least one envelope was
# reported, per the standard registered-check contract ("print one line only
# when firstmate should wake") - this is what makes the watcher's own generic
# wrapper notice and exit/wake for this cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DROP_DIR="$STATE/captain-drop"
CONSUMED_DIR="$DROP_DIR/.consumed"
QUIET_SECS=${FM_CAPTAIN_INPUT_QUIET_SECS:-3}

dir_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# Both the drop directory and its .consumed/ sibling must already exist at
# mode 0700, owned by the account this process runs as - fm-captain-input-enable.sh
# creates them. A missing or wrongly-permissioned directory means the channel
# was never (fully) enabled: stay silent rather than guessing a mode to create.
[ -d "$DROP_DIR" ] && [ ! -L "$DROP_DIR" ] || exit 0
[ "$(dir_mode "$DROP_DIR")" = 700 ] || exit 0
[ -d "$CONSUMED_DIR" ] && [ ! -L "$CONSUMED_DIR" ] || exit 0
[ "$(dir_mode "$CONSUMED_DIR")" = 700 ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

reported=0
summary=

for envelope in "$DROP_DIR"/*.json; do
  [ -e "$envelope" ] && [ ! -L "$envelope" ] || continue

  base=$(basename "$envelope" .json)
  case "$base" in
    ''|.*|*[!A-Za-z0-9._-]*) continue ;;
  esac

  env_age=$(fm_path_age "$envelope")
  case "$env_age" in ''|*[!0-9]*) continue ;; esac
  [ "$env_age" -ge "$QUIET_SECS" ] || continue

  id=$(jq -r '.id // empty' "$envelope" 2>/dev/null) || continue
  type=$(jq -r '.type // empty' "$envelope" 2>/dev/null) || continue
  path=$(jq -r '.path // empty' "$envelope" 2>/dev/null) || continue
  caption=$(jq -r '.caption // empty' "$envelope" 2>/dev/null) || continue

  [ -n "$id" ] && [ "$id" = "$base" ] || continue
  # Phase 1 handles screenshots only; an unrecognized type (e.g. a future
  # "audio") is left unconsumed rather than guessed at or discarded.
  [ "$type" = screenshot ] || continue
  [ -n "$path" ] || continue

  # The payload must be a direct, non-traversing child of the drop directory
  # named "<id>.<ext>" - never trust the envelope's path field past that shape,
  # since the envelope content is captain-authored but still external input.
  payload_base=$(basename -- "$path")
  [ "$path" = "$DROP_DIR/$payload_base" ] || continue
  case "$payload_base" in
    "$id".*) ;;
    *) continue ;;
  esac
  case "$payload_base" in
    *[!A-Za-z0-9._-]*) continue ;;
  esac
  [ -f "$path" ] && [ ! -L "$path" ] || continue

  payload_age=$(fm_path_age "$path")
  case "$payload_age" in ''|*[!0-9]*) continue ;; esac
  [ "$payload_age" -ge "$QUIET_SECS" ] || continue

  pointer="captain dropped a $type: $path"
  [ -n "$caption" ] && pointer="$pointer (caption: $caption)"

  fm_wake_append check "captain-input:$id" "$pointer" || exit 1

  mv -f -- "$path" "$CONSUMED_DIR/$payload_base" 2>/dev/null || true
  mv -f -- "$envelope" "$CONSUMED_DIR/$base.json" 2>/dev/null || true

  reported=$((reported + 1))
  if [ -z "$summary" ]; then
    summary="$pointer"
  else
    summary="$summary; $pointer"
  fi
done

if [ "$reported" -gt 0 ]; then
  printf '%s new captain-input drop(s): %s\n' "$reported" "$summary"
fi
