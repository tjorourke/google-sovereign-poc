#!/usr/bin/env python3
"""actor_timeline.py: summarise a multiplexing run (70-substrate-behaviours.sh).

Inputs, all written by the script into one run directory:
  results.txt     one line per invocation: ROUND SESSION_ID EXIT_CODE START END
  samples.csv     substrate.worker_assignments, sampled about once a second:
                  SAMPLE_TIME,ACTOR_NAME,WORKER_NAME   (a "-,-" row marks an empty sample)
  workers.txt     WORKER_NAME POD, from `kubectl ate get workers`
  transitions.jsonl  ate-api-server "Actor state changed" records (both replicas)
  router.log      atenet-router log since the run started

Prints placement over time, how many actors ran at once against how many
existed, resume latency (Substrate's own resuming -> running), end-to-end
latency, parking, and which actors resumed on a different worker in round 2.
"""
import collections
import datetime as dt
import json
import os
import statistics
import sys


def pct(values, p):
    if not values:
        return float("nan")
    values = sorted(values)
    k = (len(values) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def main(run):
    sessions = {}
    rounds = collections.defaultdict(list)
    for line in open(os.path.join(run, "results.txt")):
        rnd, sid, rc, start, end = line.split()
        rounds[int(rnd)].append((sid, int(rc), float(start), float(end)))
        sessions["session-" + sid] = sid
    t0 = min(s for r in rounds.values() for _, _, s, _ in r)

    pods = {}
    for line in open(os.path.join(run, "workers.txt")):
        name, pod = line.split()
        pods[name] = pod.split("/")[-1]

    # Placement samples: the set of (actor, worker) at each sample time.
    samples = collections.OrderedDict()
    for line in open(os.path.join(run, "samples.csv")):
        parts = line.strip().split(",")
        if len(parts) != 3:
            continue
        when, actor, worker = parts
        samples.setdefault(when, [])
        if actor != "-" and actor in sessions:
            samples[when].append((actor, pods.get(worker, worker)))

    # Substrate's own transition log, de-duplicated across api-server replicas.
    trans = collections.defaultdict(list)
    seen = set()
    for line in open(os.path.join(run, "transitions.jsonl")):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        actor = rec.get("ate.actor.name")
        if actor not in sessions:
            continue
        key = (rec["time"], actor, rec.get("ate.actor.state"))
        if key in seen:
            continue
        seen.add(key)
        trans[actor].append((ts(rec["time"]), rec.get("ate.actor.state"), rec.get("ate.actor.operation.name")))

    print(f"sessions: {len(sessions)} (one Substrate actor each), "
          f"workers: {len(pods)} ({', '.join(sorted(pods.values()))})")

    # 1. invocations
    for rnd in sorted(rounds):
        res = rounds[rnd]
        ok = [e - s for _, rc, s, e in res if rc == 0]
        print(f"\nround {rnd}: {len(res)} concurrent invocations, {len(ok)} succeeded, {len(res) - len(ok)} failed")
        if ok:
            print(f"  end-to-end seconds (create-to-answer incl. model call): "
                  f"p50 {pct(ok, 50):.1f}  p95 {pct(ok, 95):.1f}  max {max(ok):.1f}")

    # 2. concurrency over time
    print("\nactors assigned to a worker over time (substrate.worker_assignments):")
    peak, peak_per = 0, collections.Counter()
    for when, rows in samples.items():
        per = collections.Counter(w for _, w in rows)
        peak = max(peak, len(rows))
        for w, n in per.items():
            peak_per[w] = max(peak_per[w], n)
        cells = "  ".join(f"{w}={per.get(w, 0)}" for w in sorted(pods.values()))
        print(f"  {when}  total={len(rows):2d}  {cells}")
    print(f"  peak: {peak} running at once of {len(sessions)} actors; per worker "
          + ", ".join(f"{w} {n}" for w, n in sorted(peak_per.items())))

    # 3. resume latency and suspend
    resume, suspend_after = [], []
    for actor, events in trans.items():
        events.sort()
        for i, (t, state, op) in enumerate(events):
            if state == "resuming":
                nxt = next(((t2, s2) for t2, s2, _ in events[i + 1:] if s2 in ("running", "crashed", "suspended")), None)
                if nxt and nxt[1] == "running":
                    resume.append(nxt[0] - t)
    if resume:
        print(f"\nresume latency, Substrate resuming -> running ({len(resume)} resumes): "
              f"p50 {pct(resume, 50) * 1000:.0f} ms  p95 {pct(resume, 95) * 1000:.0f} ms  "
              f"max {max(resume) * 1000:.0f} ms")
    states = collections.Counter(s for ev in trans.values() for _, s, _ in ev)
    print("transitions logged: " + ", ".join(f"{k} {v}" for k, v in sorted(states.items())))

    # 4. capacity: what atenet-router did when no worker had room. Each A2A call
    # is one access-log line; a refused resume adds a warning naming the actor.
    router = open(os.path.join(run, "router.log")).read().splitlines()
    calls = [l for l in router if "\trequest " in l and "A2AService/SendMessage" in l]
    unavailable = [l for l in calls if "grpc.status=14" in l]
    exhausted = [l for l in router if "ResumeActor failed" in l and "no worker has room" in l]
    # Nothing parks them: kagent's A2A gateway reports such a send as not
    # accepted (KAGENT_SEND_NOT_ACCEPTED, retryAfterMs 100) and the kagent CLI
    # re-sends it every 100 ms for up to 30 s (cli/.../session/invoke.go).
    print(f"\nA2A calls through atenet-router: {len(calls)}; answered UNAVAILABLE (gRPC 14) because "
          f"ResumeActor found no worker with room: {len(unavailable)} "
          f"({len(exhausted)} 'no worker has room' refusals). Every invocation above was still answered: "
          f"kagent's gateway reported these sends as not accepted and the kagent CLI re-sent them")
    for l in exhausted[:2]:
        print("  " + l[:300])

    # 5. placement per round: did actors come back on another worker?
    def workers_in(rnd):
        # A round runs from its first invocation until the next round starts
        # (the last one: 30 s past its last answer, to see the actors suspend).
        res = rounds.get(rnd, [])
        if not res:
            return {}
        lo = min(s for _, _, s, _ in res) - 1
        nxt = rounds.get(rnd + 1)
        hi = min(s for _, _, s, _ in nxt) - 1 if nxt else max(e for _, _, _, e in res) + 30
        today = dt.datetime.fromtimestamp(t0, dt.timezone.utc).date().isoformat()
        out = collections.defaultdict(set)
        for when, rows in samples.items():
            t = ts(f"{today}T{when}Z")
            if lo <= t < hi:
                for actor, worker in rows:
                    out[actor].add(worker)
        return out

    if len(rounds) > 1:
        r1, r2 = workers_in(1), workers_in(2)
        moved = []
        for actor in sorted(set(r1) & set(r2)):
            if r1[actor] != r2[actor]:
                moved.append(f"  {actor}: round 1 on {', '.join(sorted(r1[actor]))} -> round 2 on {', '.join(sorted(r2[actor]))}")
        print(f"\nactors seen running in both rounds: {len(set(r1) & set(r2))}; "
              f"resumed on a different worker in round 2: {len(moved)}")
        print("\n".join(moved))


if __name__ == "__main__":
    main(sys.argv[1])
