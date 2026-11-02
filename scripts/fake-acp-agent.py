#!/usr/bin/env python3
"""A stand-in ACP agent for testing Lip Service. Speaks newline-delimited JSON-RPC on stdio.

usage: fake-acp-agent.py [--mode draft|permission|tool|report|error|die|slow|silent|supersede|stubborn] [--delay S] [--start-delay S] [--reply TEXT]
                         [--spawn-child TAG]

draft       streams --reply in a few chunks after --delay
permission  asks session/request_permission first, then says which option it got
tool        starts a tool call (a tool_call update) first, then streams --reply
report      replies with the _meta its session/new carried and the config options set on its sessions, as JSON
error       answers the prompt with a JSON-RPC error
die         exits during the prompt, after a line on stderr; with --marker, only the first time
slow        waits 30 s, or stops early on session/cancel
silent      never answers initialize
supersede   the first prompt streams "old " until session/cancel, then answers cancelled; later prompts stream --reply
stubborn    like supersede, but the first prompt ignores session/cancel and streams "old " for 5 s

--spawn-child starts a long sleeper tagged TAG, as npx starts node, to check that stopping the agent stops it too.
"""
import argparse, itertools, json, os, subprocess, sys, threading, time, uuid

p = argparse.ArgumentParser()
p.add_argument("--mode", default="draft")
p.add_argument("--delay", type=float, default=0.3)
p.add_argument("--start-delay", type=float, default=0.0)
p.add_argument("--reply", default="Tuesday at 3 works. I'll bring the latest cut.")
p.add_argument("--marker", default="", help="die mode: die only while this file is absent, then create it")
p.add_argument("--spawn-child", default="")
args = p.parse_args()
prompts = itertools.count(1)
if args.spawn_child:
    subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)", args.spawn_child])

lock = threading.Lock()
answers, cancelled = {}, threading.Event()
model = {"value": "fast-model"}
seen = {"meta": None, "options": []}


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
    if args.mode == "report":
        reply = json.dumps(seen, sort_keys=True)
    if args.mode == "tool":
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": {
            "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run touch /tmp/injected", "kind": "execute", "status": "pending"}}})
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
        send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1, "agentCapabilities": {}, "agentInfo": {"name": "fake", "version": "1"}}})
    elif method == "session/new":
        seen["meta"] = params.get("_meta")
        send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "s-" + uuid.uuid4().hex[:8], "configOptions": options(),
                                                       "models": {"currentModelId": "fast-model", "availableModels": [
                                                           {"modelId": "fast-model", "name": "Fast"}, {"modelId": "full-model", "name": "Full"}]}}})
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
