#!/usr/bin/env python3
"""A stand-in ACP agent for testing Lip Service. Speaks newline-delimited JSON-RPC on stdio.

usage: fake-acp-agent.py [--mode draft|permission|tool|steps|report|echo|error|die|slow|silent|supersede|stubborn] [--delay S] [--start-delay S] [--reply TEXT]
                         [--spawn-child TAG]
                         [--resume] [--load] [--sessions FILE] [--unknown replace|null|error]

draft       streams --reply in a few chunks after --delay
permission  asks session/request_permission first, then says which option it got
tool        starts a tool call (a tool_call update) first, then streams --reply
steps       runs four tools in a row with Hermes's titles, each for --step-time seconds, then streams --reply
report      replies with the _meta its session/new carried and the config options set on its sessions, as JSON
echo        replies "You said: " and the prompt's last line, so a test can see what reached the agent; every prompt is
            also appended to $FAKE_ACP_PROMPTS when that is set
error       answers the prompt with a JSON-RPC error
die         exits during the prompt, after a line on stderr; with --marker, only the first time
slow        waits 30 s, or stops early on session/cancel
silent      never answers initialize
supersede   the first prompt streams "old " until session/cancel, then answers cancelled; later prompts stream --reply
stubborn    like supersede, but the first prompt ignores session/cancel and streams "old " for 5 s

--resume and --load advertise session/resume and session/load. Both open a session this agent made before, and --sessions FILE
makes the agent remember its sessions between processes, as Hermes does in its history. They send the session's old turn back
as an update first, as Hermes does, which a talk must not say. For an id it doesn't know, --unknown says what happens:
replace opens a new session and names it in _meta.hermes.sessionProvenance, as Hermes's resume does (the default); null answers
null, as Hermes's load does; error answers an error.

--spawn-child starts a long sleeper tagged TAG, as npx starts node, to check that stopping the agent stops it too.
"""
import argparse, itertools, json, os, subprocess, sys, threading, time, uuid

p = argparse.ArgumentParser()
p.add_argument("--mode", default="draft")
p.add_argument("--step-time", type=float, default=1.6)
p.add_argument("--delay", type=float, default=0.3)
p.add_argument("--start-delay", type=float, default=0.0)
p.add_argument("--reply", default="Tuesday at 3 works. I'll bring the latest cut.")
p.add_argument("--marker", default="", help="die mode: die only while this file is absent, then create it")
p.add_argument("--spawn-child", default="")
p.add_argument("--resume", action="store_true")
p.add_argument("--load", action="store_true")
p.add_argument("--sessions", default="")
p.add_argument("--unknown", default="replace", choices=["replace", "null", "error"])
args = p.parse_args()
prompts = itertools.count(1)
if args.spawn_child:
    subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)", args.spawn_child])

lock = threading.Lock()
answers, cancelled = {}, threading.Event()
model = {"value": "fast-model"}
seen = {"meta": None, "options": []}
known = set()
if args.sessions and os.path.exists(args.sessions):
    known = set(open(args.sessions).read().split())


def remember(session):
    known.add(session)
    if args.sessions:
        with open(args.sessions, "a") as f:
            f.write(session + "\n")


def new_session_result(session, extra=None):
    result = {"sessionId": session, "configOptions": options(),
              "models": {"currentModelId": "fast-model", "availableModels": [
                  {"modelId": "fast-model", "name": "Fast"}, {"modelId": "full-model", "name": "Full"}]}}
    result.update(extra or {})
    return result


def send(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def options():
    return [{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model["value"],
             "options": [{"value": "fast-model", "name": "Fast"}, {"value": "full-model", "name": "Full"}]}]


def chunk(session, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": {
        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


def prompt(rid, params):
    session = params["sessionId"]
    if args.mode == "stubborn" and next(prompts) == 1:
        started = time.time()
        while time.time() - started < 5:
            chunk(params["sessionId"], "old ")
            time.sleep(0.1)
        return send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
    if args.mode == "supersede" and next(prompts) == 1:
        started = time.time()
        while not cancelled.wait(0.1) and time.time() - started < 3:
            chunk(session, "old ")
        return send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled" if cancelled.is_set() else "end_turn"}})
    if args.mode == "error":
        time.sleep(args.delay)
        return send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "model overloaded"}})
    if args.mode == "die" and not (args.marker and os.path.exists(args.marker)):
        if args.marker:
            open(args.marker, "w").close()
        time.sleep(args.delay)
        sys.stderr.write("fake agent: crashed on purpose\n")
        sys.stderr.flush()
        os._exit(3)
    if args.mode == "slow":
        cancelled.wait(30)
        return send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled" if cancelled.is_set() else "end_turn"}})
    reply = args.reply
    text = "".join(block.get("text", "") for block in params.get("prompt") or [] if isinstance(block, dict))
    if os.environ.get("FAKE_ACP_PROMPTS"):
        with open(os.environ["FAKE_ACP_PROMPTS"], "a") as f:
            f.write(json.dumps({"session": session, "text": text}) + "\n")
    if args.mode == "echo":
        reply = "You said: " + (text.strip().splitlines() or [""])[-1]
    if args.mode == "report":
        reply = json.dumps(seen, sort_keys=True)
    if args.mode == "tool":
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": {
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run touch /tmp/injected", "kind": "execute", "status": "pending"}}})
    if args.mode == "steps":
        for n, (title, kind) in enumerate([("skill_view: productivity/media-request", "read"),
                                           ("terminal: t3-run status 1a7431fb-4f9e-45ec", "execute"),
                                           ("terminal: ~/bin/gog --account me@example.com gmail search 'from:zach' --max 5", "execute"),
                                           ("read_file: plan.md", "read")]):
            for status in ("pending", "completed"):
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": {
                    "sessionUpdate": "tool_call" if status == "pending" else "tool_call_update", "toolCallId": f"s{n}",
                    "title": title, "kind": kind, "status": status}}})
                if status == "pending":
                    time.sleep(args.step_time)
    if args.mode == "permission":
        ask = "perm-" + uuid.uuid4().hex[:6]
        got = threading.Event()
        answers[ask] = (got, None)
        send({"jsonrpc": "2.0", "id": ask, "method": "session/request_permission", "params": {
            "sessionId": session, "toolCall": {"toolCallId": "t1", "title": "Read ~/Documents/notes.txt", "kind": "read"},
            "options": [{"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                        {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
                        {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]}})
        got.wait(120)
        outcome = answers[ask][1] or {}
        picked = outcome.get("optionId") if outcome.get("outcome") == "selected" else "cancelled"
        reply = f"Permission answer: {picked}. " + reply
    time.sleep(args.delay)
    words = reply.split(" ")
    for i in range(0, len(words), 3):
        chunk(session, " ".join(words[i:i + 3]) + (" " if i + 3 < len(words) else ""))
        time.sleep(0.03)
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def handle(m):
    if "method" not in m:
        if m.get("id") in answers:
            event, _ = answers[m["id"]]
            answers[m["id"]] = (event, (m.get("result") or {}).get("outcome"))
            event.set()
        return
    method, rid, params = m["method"], m.get("id"), m.get("params") or {}
    if method == "initialize":
        if args.mode == "silent":
            return
        time.sleep(args.start_delay)
        capabilities = {"loadSession": args.load}
        if args.resume:
            capabilities["sessionCapabilities"] = {"resume": {}}
        send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1, "agentCapabilities": capabilities, "agentInfo": {"name": "fake", "version": "1"}}})
    elif method == "session/new":
        seen["meta"] = params.get("_meta")
        session = "s-" + uuid.uuid4().hex[:8]
        remember(session)
        send({"jsonrpc": "2.0", "id": rid, "result": new_session_result(session)})
    elif method in ("session/resume", "session/load") and not ((method == "session/resume" and args.resume) or (method == "session/load" and args.load)):
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})
    elif method in ("session/resume", "session/load"):
        asked = params.get("sessionId", "")
        seen["servers"] = len(params.get("mcpServers") or [])
        if asked in known:
            # The old turn comes back first, as Hermes replays history; it must never be said or shown.
            chunk(asked, "OLD TURN REPLAY ")
            send({"jsonrpc": "2.0", "id": rid, "result": {k: v for k, v in new_session_result(asked).items() if k != "sessionId"}})
        elif args.unknown == "null":
            send({"jsonrpc": "2.0", "id": rid, "result": None})
        elif args.unknown == "error":
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "session not found"}})
        else:
            session = "s-" + uuid.uuid4().hex[:8]
            remember(session)
            send({"jsonrpc": "2.0", "id": rid, "result": {k: v for k, v in new_session_result(session).items() if k != "sessionId"}
                  | {"_meta": {"hermes": {"sessionProvenance": {"acpSessionId": session}}}}})
    elif method == "session/set_config_option" and args.mode == "no-mode" and params.get("configId") == "mode":
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "unknown config option: mode"}})
    elif method == "session/set_config_option":
        seen["options"].append([params.get("configId"), params.get("value")])
        model["value"] = params.get("value", model["value"])
        send({"jsonrpc": "2.0", "id": rid, "result": {"configOptions": options()}})
    elif method == "session/set_model":
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif method == "session/prompt":
        threading.Thread(target=prompt, args=(rid, params), daemon=True).start()
    elif method == "session/cancel":
        cancelled.set()
    elif rid is not None:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})


for line in sys.stdin:
    line = line.strip()
    if line:
        handle(json.loads(line))
