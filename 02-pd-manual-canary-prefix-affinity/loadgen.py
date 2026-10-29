#!/usr/bin/env python3
"""Multi-turn chat traffic for the rollout probe. Runs inside the probe pod; stdlib only.

    loadgen.py run                 hot sessions + long streams + canaries, until killed
    loadgen.py cold-seed N TAG     turn 1 of N cold sessions named cold-TAG-<k>, then exit
    loadgen.py cold-probe N TAG    their turn 2, then exit

Hot sessions. WORKERS workers each run chat sessions of TURNS turns, one request in flight
at a time, with THINK seconds (+-50%) between turns, as a user or an agent would take, so a
session spans the rollout steps instead of finishing between them. A session opens with a long unique first user message (PREFIX_WORDS words), and
every turn resends the whole conversation plus a short new user message, so from turn 2 on
almost all of the prompt is a prefix the serving pods have cached -- if the request lands on
them. In P/D the response comes from the decode pod, which has pulled the whole prompt's KV,
so its cached_tokens says little; rollout.sh watch records the prefill pods' prefix-cache
counters instead. The x-llm-d-disagg-revision header of each turn says which revision served
it, so the report can count how often a session moved between revisions.

Long streams. LONG workers each keep one streaming request of LONG_TOKENS tokens in flight,
so there are always requests spanning whatever the rollout stops.

Canaries. Every CANARY_EVERY-th hot request is instead a fixed greedy question whose answer
is checked: a broken KV cache returns 200 with the wrong text, and only a canary notices.

Cold sessions. cold-seed sends turn 1 of N sessions with long unique prefixes (COLD_WORDS
words) and records which vLLM pod served each; cold-probe, run later, sends turn 2. Nothing
touches those prefixes in between, so only a router that knows what each pod cached -- for a
router started after the seed, only one that loaded the pods' KV-cache snapshots -- can send
turn 2 back to the pod that holds turn 1.

One JSON line per request ($OUT, default /results/requests.jsonl; cold ones go to
/results/cold-seed-TAG.jsonl and /results/cold-probe-TAG.jsonl):

    t0, dur   start (epoch s) and seconds to the full response
    kind      turn | canary | long | cold-seed | cold-probe
    sess,turn session id and turn number (1-based)
    code      HTTP status, 0 for a transport error (`err` says what)
    ok        the request did what it should (right length, right canary answer)
    ptok,ctok prompt tokens, of which served from the prefix cache
    up        x-upstream-host: the vLLM pod (ip:port) that served it
    rev       x-llm-d-disagg-revision, when a rollout screener is in the path
"""
import http.client
import json
import os
import random
import sys
import threading
import time
import uuid
from urllib.parse import urlparse

URL = urlparse(os.environ.get("URL", "http://pdcanary-router:80"))
MODEL = os.environ.get("MODEL", "deepseek-ai/DeepSeek-V2-Lite-Chat")
WORKERS = int(os.environ.get("WORKERS", "8"))
TURNS = int(os.environ.get("TURNS", "12"))
PREFIX_WORDS = int(os.environ.get("PREFIX_WORDS", "1500"))
TURN_WORDS = int(os.environ.get("TURN_WORDS", "40"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "64"))
THINK = float(os.environ.get("THINK", "5"))
LONG = int(os.environ.get("LONG", "2"))
LONG_TOKENS = int(os.environ.get("LONG_TOKENS", "12000"))
COLD_WORDS = int(os.environ.get("COLD_WORDS", "3000"))
CANARY_EVERY = int(os.environ.get("CANARY_EVERY", "10"))
SESSION_HEADER = os.environ.get("SESSION_HEADER", "")
TIMEOUT = float(os.environ.get("TIMEOUT", "600"))
OUT = os.environ.get("OUT", "/results/requests.jsonl")
RUN_ID = os.environ.get("RUN_ID", uuid.uuid4().hex[:8])

SYSTEM = "You are a helpful assistant. Answer briefly."
CANARY_Q = "What is the capital of France? Answer with one word."
CANARY_EXPECT = "Paris"

WORDS = ("time year people way day man thing woman life child world school state "
         "family student group country problem hand part place case week company "
         "system program question work government number night point home water "
         "room mother area money story fact month lot right study book eye job "
         "word business issue side kind head house service friend father power "
         "hour game line end member law car city community name").split()

lock = threading.Lock()
stats = {"n": 0, "bad": 0, "revs": {}}


def words(rng, n):
    return " ".join(rng.choices(WORDS, k=n))


class Client:
    """One keep-alive connection; reconnects after an error or a Connection: close."""

    def __init__(self):
        self.conn = None

    def post(self, body, headers, stream=False):
        """Returns (status, headers, payload, ttft). payload is the parsed JSON body, or for a
        stream the concatenated text and the final usage."""
        if self.conn is None:
            self.conn = http.client.HTTPConnection(URL.hostname, URL.port or 80, timeout=TIMEOUT)
        t = time.monotonic()
        try:
            self.conn.request("POST", "/v1/chat/completions", json.dumps(body),
                              {"Content-Type": "application/json", **headers})
            resp = self.conn.getresponse()
            ttft = None
            if resp.status == 200 and stream:
                text, usage = [], {}
                for raw in resp:
                    line = raw.decode().strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    chunk = json.loads(data)
                    if ttft is None:
                        ttft = time.monotonic() - t
                    for c in chunk.get("choices", []):
                        text.append(c.get("delta", {}).get("content") or "")
                    usage = chunk.get("usage") or usage
                resp.read()  # the rest of the chunked body, or the connection is not reusable
                payload = {"text": "".join(text), "usage": usage}
            else:
                raw = resp.read()
                payload = json.loads(raw) if resp.status == 200 else raw[:300].decode("utf-8", "replace")
            if resp.getheader("connection", "").lower() == "close":
                self.close()
            return resp.status, resp, payload, ttft
        except Exception:
            self.close()
            raise

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:
                pass
        self.conn = None


def send(client, kind, sess, turn, messages, max_tokens, stream=False, check=None):
    rid = f"{kind}-{sess}-{turn}-{uuid.uuid4().hex[:8]}"
    headers = {"x-request-id": rid}
    if SESSION_HEADER:
        headers[SESSION_HEADER] = sess
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens,
            "temperature": 0, "ignore_eos": check is None, "min_tokens": 0 if check else max_tokens}
    if stream:
        body.update(stream=True, stream_options={"include_usage": True})
    rec = {"t0": round(time.time(), 3), "kind": kind, "sess": sess, "turn": turn, "id": rid}
    t = time.monotonic()
    reply = ""
    try:
        status, resp, payload, ttft = client.post(body, headers, stream)
        rec["code"] = status
        rec["up"] = resp.getheader("x-upstream-host", "")
        rec["rev"] = resp.getheader("x-llm-d-disagg-revision", "")
        if ttft is not None:
            rec["ttft"] = round(ttft, 4)
        if status == 200:
            if stream:
                reply, usage = payload["text"], payload["usage"]
            else:
                reply, usage = payload["choices"][0]["message"].get("content") or "", payload.get("usage", {})
            rec["ptok"] = usage.get("prompt_tokens")
            rec["ctok"] = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
            rec["ntok"] = usage.get("completion_tokens")
            rec["ok"] = check(reply) if check else rec["ntok"] == max_tokens
        else:
            rec["ok"] = False
            rec["err"] = payload
    except Exception as e:  # transport error: record it, reconnect next time
        rec.update(code=0, ok=False, err=f"{type(e).__name__}: {e}"[:300])
    rec["dur"] = round(time.monotonic() - t, 4)
    return rec, reply


def record(out, rec):
    with lock:
        out.write(json.dumps(rec) + "\n")
        stats["n"] += 1
        stats["bad"] += 0 if rec.get("ok") else 1
        rev = rec.get("rev", "")
        stats["revs"][rev] = stats["revs"].get(rev, 0) + 1


def hot_worker(i, out):
    rng = random.Random(f"{RUN_ID}-{i}")
    client = Client()
    n = 0
    s = 0
    while True:
        s += 1
        sess = f"{RUN_ID}-w{i}-s{s}"
        # The unique first user message is the session's prefix-affinity key and the bulk of
        # its cached prefix.
        messages = [{"role": "system", "content": SYSTEM},
                    {"role": "user", "content": f"[{sess}] Read this and wait for questions. " + words(rng, PREFIX_WORDS)}]
        for turn in range(1, TURNS + 1):
            n += 1
            if CANARY_EVERY and n % CANARY_EVERY == 0:
                cid = uuid.uuid4().hex[:8]
                rec, _ = send(client, "canary", f"canary-{cid}", 1,
                              [{"role": "system", "content": f"{SYSTEM} [{cid}]"},
                               {"role": "user", "content": CANARY_Q}],
                              8, check=lambda r: CANARY_EXPECT in r)
                record(out, rec)
            rec, reply = send(client, "turn", sess, turn, messages, MAX_TOKENS)
            record(out, rec)
            if not rec["ok"]:
                time.sleep(0.2)  # a fail-closed router answers in a millisecond
                break            # start a fresh session
            messages += [{"role": "assistant", "content": reply},
                         {"role": "user", "content": words(rng, TURN_WORDS)}]
            time.sleep(rng.uniform(0.5, 1.5) * THINK)


def long_worker(i, out):
    rng = random.Random(f"{RUN_ID}-long-{i}")
    client = Client()
    s = 0
    while True:
        s += 1
        sess = f"{RUN_ID}-l{i}-s{s}"
        rec, _ = send(client, "long", sess, 1,
                      [{"role": "user", "content": f"[{sess}] Write a long story. " + words(rng, 200)}],
                      LONG_TOKENS, stream=True)
        record(out, rec)
        if not rec["ok"]:
            time.sleep(1)


def cold_messages(sess):
    rng = random.Random(sess)
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": f"[{sess}] Read this and wait for questions. " + words(rng, COLD_WORDS)}]


def cold(mode, n, tag):
    """cold-seed: turn 1 of sessions cold-0..n-1. cold-probe: their turn 2, built on the reply
    cold-seed recorded, so the whole turn-1 conversation is a cached prefix on one pod."""
    client = Client()
    seeds = {}
    if mode == "cold-probe":
        with open(f"/results/cold-seed-{tag}.jsonl") as f:
            for line in f:
                r = json.loads(line)
                seeds[r["sess"]] = r
    with open(f"/results/{mode}-{tag}.jsonl", "a", buffering=1) as out:
        for k in range(n):
            sess = f"cold-{tag}-{k}"
            messages = cold_messages(sess)
            if mode == "cold-probe":
                messages += [{"role": "assistant", "content": seeds[sess]["reply"]},
                             {"role": "user", "content": "Summarize it in one sentence."}]
            rec, reply = send(client, mode, sess, 1 if mode == "cold-seed" else 2, messages, MAX_TOKENS)
            if mode == "cold-seed":
                rec["reply"] = reply
            else:
                rec["seed_up"] = seeds[sess].get("up", "")
            out.write(json.dumps(rec) + "\n")
            print(json.dumps({k: rec.get(k) for k in ("sess", "code", "up", "ptok", "ctok", "seed_up")}), flush=True)


def run():
    out = open(OUT, "a", buffering=1)
    for i in range(WORKERS):
        threading.Thread(target=hot_worker, args=(i, out), daemon=True).start()
    for i in range(LONG):
        threading.Thread(target=long_worker, args=(i, out), daemon=True).start()
    print(f"loadgen {RUN_ID}: {WORKERS} session workers ({TURNS} turns {THINK:g}s apart, {PREFIX_WORDS}-word prefix), "
          f"{LONG} long streams ({LONG_TOKENS} tokens) -> {URL.geturl()} ({MODEL})", flush=True)
    while True:
        time.sleep(10)
        with lock:
            snap = dict(stats)
            stats.update(n=0, bad=0, revs={})
        print(f"{time.strftime('%H:%M:%S')} last10s: requests={snap['n']} bad={snap['bad']} "
              f"by revision={snap['revs']}", flush=True)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "run"
    if mode == "run":
        run()
    elif mode in ("cold-seed", "cold-probe"):
        cold(mode, int(sys.argv[2]), sys.argv[3])
    else:
        sys.exit(__doc__)
