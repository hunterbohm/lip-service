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
check "every permission request is refused" 'rows[0]["asked"]=="Read ~/Documents/notes.txt" and rows[0]["text"].startswith("Permission answer: reject.")' \
    --command "$fake --mode permission" --runs 1
check "a draft that starts a tool is stopped at the first one" \
    'rows[0]["tools"]==1 and "tried to use a tool" in rows[0].get("error","") and "text" not in rows[0]' --command "$fake --mode tool" --runs 1
check "a draft with no tool reports none" 'rows[0]["tools"]==0 and "error" not in rows[0]' --command "$fake --mode draft" --runs 1
check "Claude Code drafts start with no tools" \
    'json.loads(rows[0]["text"])["meta"]=={"claudeCode":{"options":{"tools":[],"strictMcpConfig":True}}}' \
    --command "$fake --mode report" --preset claude --runs 1
check "Codex drafts start read-only, after the draft options" \
    'json.loads(rows[0]["text"])["options"]==[["model","fast-model"],["mode","read-only"]]' \
    --command "$fake --mode report" --preset codex --option model=fast-model --runs 1
check "a Codex that can't switch to read-only gets no draft" \
    '"switch its tools off" in rows[0].get("error","") and "text" not in rows[0]' \
    --command "$fake --mode no-mode" --preset codex --runs 1
check "an agent with no tool switch is sent nothing extra" \
    'json.loads(rows[0]["text"])=={"meta":None,"options":[]}' --command "$fake --mode report" --preset hermes --runs 1
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

# Live talk sessions: a talk goes on in the last talk's session when the agent can open it again and is set to.
thread=$(mktemp -u /tmp/fake-acp-thread.XXXXXX); known=$(mktemp -u /tmp/fake-acp-known.XXXXXX)
check "a talk goes on in the last talk's session while the agent is still running it" \
    'len({r["session"] for r in rows})==1 and [r["continued"] for r in rows]==[False,True,True] and rows[2]["text"]=="You said: talk 3"' \
    --command "$fake --mode echo --resume --sessions $known" --talk-sessions 3 --continue --thread "$thread" --start-over
check "a talk after the agent was stopped opens the same session again, and never says its replayed history" \
    'len({r["session"] for r in rows})==1 and [r["continued"] for r in rows]==[True,True,True] and all(r["text"].startswith("You said: talk ") for r in rows)' \
    --command "$fake --mode echo --resume --sessions $known" --talk-sessions 3 --continue --thread "$thread" --cold
check "the next run of the app picks the conversation up from the file" \
    'rows[0]["continued"]==True and rows[0]["open_s"]<5' \
    --command "$fake --mode echo --resume --sessions $known" --talk-sessions 1 --continue --thread "$thread"
check "starting a new conversation opens a new session, and the one after goes on in that" \
    'rows[0]["continued"]==False and rows[1]["continued"]==True and rows[0]["session"]==rows[1]["session"]' \
    --command "$fake --mode echo --resume --sessions $known" --talk-sessions 2 --continue --thread "$thread" --start-over
# Each of these first has a talk in a fake agent, then loses that agent's memory of the session, as when Hermes's history was cleared.
rm -f "$thread" "$known"
lost() { "$bin" --agent-bench --speech 0.2 --command "$1" --talk-sessions 1 --continue --thread "$thread" >/dev/null 2>&1; rm -f "$known"; }
lost "$fake --mode echo --resume --sessions $known"
check "an agent that no longer has the session starts a new conversation in the one it opened, and the next talk goes on there" \
    'rows[0]["continued"]==False and rows[1]["continued"]==True and rows[0]["session"]==rows[1]["session"] and "error" not in rows[0]' \
    --command "$fake --mode echo --resume --sessions $known" --talk-sessions 2 --continue --thread "$thread" --cold
rm -f "$thread" "$known"
check "an agent without resume gets a new session for every talk, as before" \
    'len({r["session"] for r in rows})==3 and not any(r["continued"] for r in rows)' \
    --command "$fake --mode echo" --talk-sessions 3 --continue --thread "$thread"
rm -f "$thread" "$known"
check "an agent not set to carry on gets a new session for every talk, though it could" \
    'len({r["session"] for r in rows})==3 and not any(r["continued"] for r in rows)' \
    --command "$fake --mode echo --resume" --talk-sessions 3 --thread "$thread"
rm -f "$thread" "$known"
lost "$fake --mode echo --load --unknown null --sessions $known"
check "an agent that can only load, and says null for a session it lost, starts a new conversation" \
    'rows[0]["continued"]==False and rows[1]["continued"]==True and rows[0]["session"]==rows[1]["session"] and "error" not in rows[0]' \
    --command "$fake --mode echo --load --unknown null --sessions $known" --talk-sessions 2 --continue --thread "$thread" --cold
rm -f "$thread" "$known"
lost "$fake --mode echo --resume --unknown error --sessions $known"
check "an agent that errors on the session it lost starts a new conversation" \
    'all("error" not in r for r in rows) and rows[0]["continued"]==False' \
    --command "$fake --mode echo --resume --unknown error --sessions $known" --talk-sessions 1 --continue --thread "$thread"
rm -f "$thread" "$known"
exit $failed
