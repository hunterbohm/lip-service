#!/bin/zsh
# Runs the app's agent client against the fake ACP agent in each of its modes and checks what came back.
# usage: test-agents.sh DICTATION_BINARY
set -u
bin=$1; fake="python3 $(cd "$(dirname "$0")" && pwd)/fake-acp-agent.py"; failed=0
marker=$(mktemp -u /tmp/fake-acp-marker.XXXXXX)
check() {
    local name=$1 want=$2; shift 2
    local out; out=$("$bin" --agent-bench --speech 0.2 "$@" 2>/dev/null)
    if print -r -- "$out" | python3 -c "import json,sys; rows=[json.loads(l) for l in sys.stdin if l.startswith('{')]; sys.exit(0 if ($want) else 1)"; then
        print "pass  $name"
    else
        print "FAIL  $name"; print -r -- "$out"; failed=1
    fi
}
check "a draft streams in" 'rows[0]["text"]=="Tuesday at 3 works. I'"'"'ll bring the latest cut." and rows[0]["prompt_to_first_s"]>=0.3' \
    --command "$fake --mode draft --delay 0.3" --runs 1
check "the warm path skips start and session" 'rows[1]["session_wait_s"]<0.05 and rows[1]["prompt_to_first_s"]<0.5' \
    --command "$fake --mode draft --delay 0.1 --start-delay 1" --runs 2
check "a request made while the agent is still starting waits for it" 'all(r.get("text","").startswith("Tuesday") for r in rows)' \
    --command "$fake --mode draft --start-delay 1.5" --runs 2 --cold
check "a permission answer reaches the agent" 'rows[0]["asked"]=="Read ~/Documents/notes.txt" and rows[0]["text"].startswith("Permission answer: always.")' \
    --command "$fake --mode permission" --answer always --runs 1
check "no answer refuses" 'rows[0]["text"].startswith("Permission answer: reject.")' --command "$fake --mode permission" --runs 1
check "an agent error is shown" '"model overloaded" in rows[0].get("error","")' --command "$fake --mode error" --runs 1
check "a dead agent says why, and the next request starts it again" \
    '"crashed on purpose" in rows[0].get("error","") and rows[1].get("text","").startswith("Tuesday")' \
    --command "$fake --mode die --marker $marker" --runs 2
check "a missing agent says it isn't installed" '"installed" in rows[0].get("error","")' --command "no-such-agent-xyz acp" --runs 1
check "a change cancels the draft still streaming, and only the change comes back" \
    'rows[0]["first_stop"]=="cancelled" and rows[0]["text"]=="Tuesday at 3 works. I'"'"'ll bring the latest cut."' \
    --command "$fake --mode supersede" --runs 1 --supersede 0.5
check "a turn that ignores the cancel retires its session, so none of its output reaches the change" \
    '"new session" in rows[0].get("error", "") and "old" not in rows[0].get("text", "")' \
    --command "$fake --mode stubborn" --runs 1 --supersede 0.5
check "an agent still answering is not stopped as idle" 'rows[0].get("text","").startswith("Tuesday")' \
    --command "$fake --mode draft --delay 3" --runs 1 --idle-limit 1
tag="fake-acp-child-$$"
check "stopping an agent stops what it started" 'rows[0].get("text","").startswith("Tuesday")' \
    --command "$fake --mode draft --spawn-child $tag" --runs 1
sleep 1
if pgrep -f "$tag" >/dev/null; then print "FAIL  the agent's child outlived it"; pkill -f "$tag"; failed=1; else print "pass  the agent's child stopped with it"; fi
rm -f "$marker"
exit $failed
