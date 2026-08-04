#!/usr/bin/env bash
# fm-context-usage.sh - report the current conversation's measured context usage.
#
# Reads the newest usage record from the current session transcript without
# writing state, changing watcher behavior, or attempting compaction. A Claude
# session is selected only when the invoking process identifies one active
# Claude ancestor. When that ancestor's CLAUDE_CODE_SESSION_ID is set, its
# project directory's <session-id>.jsonl is the exact transcript; otherwise
# the directory's newest transcript is used only when newer than that
# process started. An explicit FM_CONTEXT_USAGE_TRANSCRIPT or PI_SESSION_FILE
# is an exact session binding; otherwise an ambiguous or unprovable selection
# is reported unknown.
# Claude Opus 5 and the current Claude model families documented at
# docs.anthropic.com use the documented 1,000,000-token window; an explicit
# FM_CONTEXT_WINDOW_TOKENS or config/context-window-tokens override is honored.
#
# Usage:
#   fm-context-usage.sh          print a human-readable measurement
#   fm-context-usage.sh --machine print one key=value record for skills
#   fm-context-usage.sh --help   print this usage
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BAND_PERCENT=50
MODE=human

usage() {
  sed -n '2,20{s/^# \{0,1\}//;p;}' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --machine) MODE=machine; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      printf 'fm-context-usage.sh: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

unknown() {
  local reason=$1
  if [ "$MODE" = machine ]; then
    printf 'status=unknown reason=%s\n' "$reason"
  else
    printf 'context usage: unknown (%s)\n' "$reason"
  fi
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)
      (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")") || return 1
      ;;
  esac
}

file_mtime() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1" 2>/dev/null
  fi
}

claude_project_slug() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

process_start_epoch() {
  local pid=$1 raw
  raw=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//') || return 1
  [ -n "$raw" ] || return 1
  date -d "$raw" +%s 2>/dev/null && return 0
  date -j -f '%a %b %d %H:%M:%S %Y' "$raw" +%s 2>/dev/null
}

ancestor_claude_pid() {
  local pid=$$ parent command first
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$parent" in ''|*[!0-9]*) return 1 ;; esac
    command=$(ps -o command= -p "$parent" 2>/dev/null || true)
    first=${command%% *}
    case "$(basename "$first")" in
      claude|claude-code) printf '%s\n' "$parent"; return 0 ;;
    esac
    pid=$parent
  done
  return 1
}

newest_transcript_in() {
  local dir=$1 file mtime best='' best_mtime=-1 tie=0
  [ -d "$dir" ] || return 1
  for file in "$dir"/*.jsonl; do
    [ -f "$file" ] || continue
    mtime=$(file_mtime "$file") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best=$file
      best_mtime=$mtime
      tie=0
    elif [ "$mtime" -eq "$best_mtime" ]; then
      tie=1
    fi
  done
  [ -n "$best" ] || return 1
  [ "$tie" -eq 0 ] || return 2
  printf '%s\n' "$best"
}

TRANSCRIPT=
TRANSCRIPT_REASON=
CLAUDE_PID=

if [ -n "${FM_CONTEXT_USAGE_TRANSCRIPT:-}" ]; then
  TRANSCRIPT=$(absolute_path "$FM_CONTEXT_USAGE_TRANSCRIPT" 2>/dev/null || true)
  [ -n "$TRANSCRIPT" ] || TRANSCRIPT_REASON=transcript-path-unreadable
elif [ -n "${PI_SESSION_FILE:-}" ]; then
  TRANSCRIPT=$(absolute_path "$PI_SESSION_FILE" 2>/dev/null || true)
  [ -n "$TRANSCRIPT" ] || TRANSCRIPT_REASON=pi-session-path-unreadable
else
  CLAUDE_PID=$(ancestor_claude_pid 2>/dev/null || true)
  if [ -n "$CLAUDE_PID" ]; then
    CLAUDE_CWD=$(readlink "/proc/$CLAUDE_PID/cwd" 2>/dev/null || true)
    if [ -z "$CLAUDE_CWD" ]; then
      CLAUDE_CWD=$(ps -o command= -p "$CLAUDE_PID" >/dev/null 2>&1 && pwd -P || true)
    fi
    if [ -n "$CLAUDE_CWD" ]; then
      PROJECT_DIR="$HOME/.claude/projects/$(claude_project_slug "$CLAUDE_CWD")"
      if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
        SESSION_TRANSCRIPT="$PROJECT_DIR/${CLAUDE_CODE_SESSION_ID}.jsonl"
        if [ -f "$SESSION_TRANSCRIPT" ]; then
          TRANSCRIPT=$SESSION_TRANSCRIPT
        else
          TRANSCRIPT_REASON=session-id-transcript-missing
        fi
      else
        TRANSCRIPT=$(newest_transcript_in "$PROJECT_DIR" 2>/dev/null || true)
        if [ -z "$TRANSCRIPT" ]; then
          TRANSCRIPT_REASON=ambiguous-or-missing-current-transcript
        fi
        if [ -n "$TRANSCRIPT" ]; then
          TRANSCRIPT_MTIME=$(file_mtime "$TRANSCRIPT" 2>/dev/null || printf '%s' 0)
          PROCESS_STARTED=$(process_start_epoch "$CLAUDE_PID" 2>/dev/null || printf '%s' 0)
          case "$TRANSCRIPT_MTIME" in
            ''|*[!0-9]*) TRANSCRIPT_REASON=transcript-age-unverifiable; TRANSCRIPT= ;;
            *)
              case "$PROCESS_STARTED" in
                ''|*[!0-9]*) TRANSCRIPT_REASON=transcript-age-unverifiable; TRANSCRIPT= ;;
                *)
                  if [ "$TRANSCRIPT_MTIME" -lt "$PROCESS_STARTED" ]; then
                    TRANSCRIPT_REASON=selected-transcript-predates-active-session
                    TRANSCRIPT=
                  fi
                  ;;
              esac
              ;;
          esac
        fi
      fi
    else
      TRANSCRIPT_REASON=current-claude-directory-unreadable
    fi
  else
    TRANSCRIPT_REASON=current-session-not-identifiable
  fi
fi

if [ -z "$TRANSCRIPT" ]; then
  unknown "${TRANSCRIPT_REASON:-current-session-not-identifiable}"
  exit 0
fi
if [ ! -f "$TRANSCRIPT" ]; then
  unknown "transcript-missing:$TRANSCRIPT"
  exit 0
fi
if [ ! -r "$TRANSCRIPT" ]; then
  unknown "transcript-unreadable:$TRANSCRIPT"
  exit 0
fi
if [ ! -s "$TRANSCRIPT" ]; then
  unknown "transcript-empty:$TRANSCRIPT"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  unknown jq-not-found
  exit 0
fi

RECORDS=$(jq -c '
  select(
    (.type == "assistant" and (.isSidechain != true) and (.message.usage != null))
    or (.type == "message" and .message.role == "assistant" and (.message.usage != null))
  )
  | if (.message.usage.input_tokens != null
        or .message.usage.cache_read_input_tokens != null
        or .message.usage.cache_creation_input_tokens != null) then
      {
        kind: "claude",
        input: .message.usage.input_tokens,
        cache_read: .message.usage.cache_read_input_tokens,
        cache_creation: .message.usage.cache_creation_input_tokens,
        model: (.message.model // .model // "unknown"),
        session: (.session_id // .sessionId // .message.session_id // "")
      }
    else
      {
        kind: "pi",
        input: .message.usage.input,
        cache_read: .message.usage.cacheRead,
        cache_creation: .message.usage.cacheWrite,
        model: (.message.model // .model // "unknown"),
        session: (.session_id // .sessionId // "")
      }
    end
' "$TRANSCRIPT" 2>/dev/null) || {
  unknown "transcript-unreadable:$TRANSCRIPT"
  exit 0
}
RECORD=$(printf '%s\n' "$RECORDS" | tail -n 1)
[ -n "$RECORD" ] || {
  unknown "no-usage-record:$TRANSCRIPT"
  exit 0
}

INPUT=$(printf '%s\n' "$RECORD" | jq -r '.input // "unknown"')
CACHE_READ=$(printf '%s\n' "$RECORD" | jq -r '.cache_read // "unknown"')
CACHE_CREATION=$(printf '%s\n' "$RECORD" | jq -r '.cache_creation // "unknown"')
MODEL=$(printf '%s\n' "$RECORD" | jq -r '.model // "unknown"')
SESSION=$(printf '%s\n' "$RECORD" | jq -r '.session // ""')
[ -n "$SESSION" ] || SESSION=$(basename "$TRANSCRIPT" .jsonl)
for value in "$INPUT" "$CACHE_READ" "$CACHE_CREATION"; do
  case "$value" in
    ''|*[!0-9]*)
      unknown "usage-record-incomplete:$TRANSCRIPT"
      exit 0
      ;;
  esac
done
TOKENS=$((INPUT + CACHE_READ + CACHE_CREATION))

WINDOW=
WINDOW_SOURCE=
WINDOW_VALUE=${FM_CONTEXT_WINDOW_TOKENS:-}
if [ -z "$WINDOW_VALUE" ] && [ -f "$CONFIG/context-window-tokens" ]; then
  WINDOW_VALUE=$(awk '!/^[[:space:]]*(#|$)/ {print $1; exit}' "$CONFIG/context-window-tokens" 2>/dev/null || true)
fi
if [ -n "$WINDOW_VALUE" ]; then
  case "$WINDOW_VALUE" in
    ''|*[!0-9]*) unknown "invalid-context-window-setting"; exit 0 ;;
    *) WINDOW=$WINDOW_VALUE; WINDOW_SOURCE=configurable ;;
  esac
else
  case "$MODEL" in
    claude-opus-5*|claude-sonnet-5*|claude-fable-5*|\
    claude-opus-4.6*|claude-opus-4.7*|claude-opus-4.8*|\
    claude-sonnet-4.5*|claude-sonnet-4.6*)
      WINDOW=1000000
      WINDOW_SOURCE=anthropic-docs
      ;;
    *)
      WINDOW_SOURCE=unknown
      ;;
  esac
fi

TRANSCRIPT_ABS=$(absolute_path "$TRANSCRIPT" 2>/dev/null || printf '%s' "$TRANSCRIPT")
if [ -z "$WINDOW" ]; then
  if [ "$MODE" = machine ]; then
    printf 'status=known tokens=%s window=unknown model=%s session=%s transcript=%s band=%.1f compact=unknown window_source=%s\n' \
      "$TOKENS" "$MODEL" "$SESSION" "$TRANSCRIPT_ABS" "$BAND_PERCENT" "$WINDOW_SOURCE"
  else
    printf 'context usage: %s tokens (window unknown; model %s; percentage unavailable; transcript %s)\n' \
      "$TOKENS" "$MODEL" "$TRANSCRIPT_ABS"
  fi
  exit 0
fi
case "$WINDOW" in
  0) unknown invalid-context-window-setting; exit 0 ;;
esac
PERCENT=$(awk -v used="$TOKENS" -v window="$WINDOW" 'BEGIN { printf "%.1f", (used * 100) / window }')
COMPACT=0
if awk -v used="$TOKENS" -v window="$WINDOW" -v band="$BAND_PERCENT" \
  'BEGIN { exit !((used * 100) >= (window * band)) }'; then
  COMPACT=1
fi
if [ "$MODE" = machine ]; then
  printf 'status=known tokens=%s percent=%s window=%s model=%s session=%s transcript=%s band=%.1f compact=%s window_source=%s\n' \
    "$TOKENS" "$PERCENT" "$WINDOW" "$MODEL" "$SESSION" "$TRANSCRIPT_ABS" "$BAND_PERCENT" "$COMPACT" "$WINDOW_SOURCE"
else
  printf 'context usage: %s tokens (%.1f%% of %s-token window; model %s; transcript %s)\n' \
    "$TOKENS" "$PERCENT" "$WINDOW" "$MODEL" "$TRANSCRIPT_ABS"
fi
