# Fast path for Claude Code hooks (Git Bash, no PowerShell). Sourced by the hook command:
#   source ".../fast.sh" "<state dir>" clear|start
# clear: removes the alert of THIS session (PostToolUse).
# start: same, and records when the prompt was sent (UserPromptSubmit), for min_task_seconds.
# Reads only the first fields of the JSON on stdin (session_id comes first): PostToolUse input can be
# hundreds of KB (tool output) and bash reads pipes one byte at a time.
s=
for _ in 1 2 3 4 5 6 7 8; do
  IFS= read -r -d ',' f || { case $f in *'"session_id"'*) ;; *) break ;; esac; }
  case $f in
    *'"session_id"'*) f=${f#*\"session_id\"}; f=${f#*\"}; s=${f%%\"*}; break ;;
  esac
done
if [ -n "$s" ]; then
  if [ "$2" = start ]; then
    [ -d "$1/start" ] || mkdir -p "$1/start"
    printf '%s' "$EPOCHSECONDS" > "$1/start/code-$s"
  fi
  [ -f "$1/alerts/code-$s.json" ] && rm -f "$1/alerts/code-$s.json"
fi
:
