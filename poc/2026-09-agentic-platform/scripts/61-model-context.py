#!/usr/bin/env python3
"""Set the existing Gemma deployment's context without replacing other settings."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tokens", type=int, default=24576)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.tokens < 2048:
        parser.error("--tokens must be at least 2048")
    deploy = Path(__file__).resolve().parents[1] / "deploy"
    config = next((p for p in (deploy / "console.kubeconfig", deploy / ".kubeconfig") if p.exists()), deploy / ".kubeconfig")
    env = {**os.environ, "KUBECONFIG": os.environ.get("GCD_KUBECONFIG", str(config))}
    command = ["kubectl", "-n", "model"]
    result = subprocess.run(command + ["get", "deployment", "llm", "-o", "json"], env=env, capture_output=True, text=True, check=True)
    deployment = json.loads(result.stdout)
    containers = deployment["spec"]["template"]["spec"]["containers"]
    index = next(i for i, c in enumerate(containers) if c["name"] == "server")
    old = containers[index]["args"]
    if "--model=google/gemma-3-27b-it" not in old:
        raise SystemExit("Expected the existing Gemma GPU deployment; no changes made")
    desired = [a for a in old if not a.startswith("--max-model-len=")] + [f"--max-model-len={args.tokens}"]
    patch = [{"op": "test", "path": "/metadata/resourceVersion", "value": deployment["metadata"]["resourceVersion"]},
             {"op": "replace", "path": f"/spec/template/spec/containers/{index}/args", "value": desired},
             {"op": "replace", "path": "/spec/strategy", "value": {"type": "Recreate"}}]
    if not args.apply:
        print(json.dumps(patch, indent=2))
    else:
        if desired != old or deployment["spec"]["strategy"]["type"] != "Recreate":
            subprocess.run(command + ["patch", "deployment", "llm", "--type=json", "-p", json.dumps(patch)], env=env, check=True)
        subprocess.run(command + ["rollout", "status", "deployment/llm", "--timeout=1200s"], env=env, check=True)
        # Older live deployments lack readiness probes. Confirm vLLM has loaded
        # the weights and serves the requested context, rather than only Running.
        check = ('import json,urllib.request; '
                 'd=json.load(urllib.request.urlopen("http://127.0.0.1:8000/v1/models",timeout=3)); '
                 f'assert any(x.get("id")=="gemma-3-27b-it" and x.get("max_model_len")=={args.tokens} for x in d["data"])')
        for _ in range(120):
            try:
                health = subprocess.run(command + ["exec", "deployment/llm", "--", "python3", "-c", check],
                                        env=env, capture_output=True, timeout=15)
                if health.returncode == 0:
                    break
            except subprocess.TimeoutExpired:
                pass
            time.sleep(5)
        else:
            raise SystemExit("Model pod rolled out, but its API did not confirm the requested context")
        print(f"Gemma ready with a {args.tokens}-token context")


if __name__ == "__main__":
    main()
