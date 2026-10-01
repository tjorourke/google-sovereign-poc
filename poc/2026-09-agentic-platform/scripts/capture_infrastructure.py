#!/usr/bin/env python3
"""Capture a credential-free live infrastructure inventory for the demo repo.

Does not export Secrets, Helm values, environment values, ConfigMaps, or state.
Those can contain passwords, signing keys, bearer tokens, and license material.
The exported runtime manifests are limited to routing/security resources.
"""
import argparse
import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import mcp_security as security


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", type=Path, default=security.LAB / "deploy/inventory.json")
    args = ap.parse_args()
    if command(["gcloud", "config", "list", "--format=json"]).get("core", {}).get("universe_domain") != "apis-berlin-build0.goog":
        raise RuntimeError("Select the Berlin gcloud configuration first")
    project = "eu0:soloio-eval"
    commands = {
        "cluster": ["container", "clusters", "describe", "agentic", "--location=u-germany-northeast1",
                    "--format=json(name,location,status,currentMasterVersion,currentNodeVersion,autopilot,network,subnetwork,privateClusterConfig,ipAllocationPolicy,workloadIdentityConfig)"],
        "forwardingRules": ["compute", "forwarding-rules", "list", "--format=json(name,region,IPAddress,IPProtocol,loadBalancingScheme,ports,portRange,target,backendService)"],
        "addresses": ["compute", "addresses", "list", "--format=json(name,address,addressType,purpose,status,region,users)"],
        "networks": ["compute", "networks", "list", "--format=json(name,autoCreateSubnetworks,routingConfig,subnetworks)"],
        "subnets": ["compute", "networks", "subnets", "list", "--format=json(name,region,ipCidrRange,secondaryIpRanges,privateIpGoogleAccess,purpose)"],
        "routers": ["compute", "routers", "describe", "agentic-router", "--region=u-germany-northeast1", "--format=json(name,region,network,nats)"],
        "sql": ["sql", "instances", "list", "--format=json(name,region,state,databaseVersion,settings.tier,settings.ipConfiguration,diskEncryptionConfiguration)"],
        "buckets": ["storage", "buckets", "list", "--format=json(name,location,default_kms_key,uniform_bucket_level_access)"],
        "dns": ["dns", "record-sets", "list", "--zone=agentic-private", "--format=json(name,type,ttl,rrdatas)"],
        "registry": ["artifacts", "repositories", "list", "--location=u-germany-northeast1", "--format=json(name,format,mode,kmsKeyName)"],
    }
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = {k: pool.submit(command, ["gcloud", *v, "--project=" + project]) for k, v in commands.items()}
        cloud = {k: f.result() for k, f in futures.items()}
    helm = ["helm", "--kubeconfig", os.environ["KUBECONFIG"]]
    if os.environ.get("KUBE_CONTEXT"):
        helm += ["--kube-context", os.environ["KUBE_CONTEXT"]]
    releases = command([*helm, "list", "-A", "-o", "json"])
    workloads = []
    for d in security.get("deployments,statefulsets,daemonsets"):
        ns = d["metadata"]["namespace"]
        if ns.startswith(("kube-", "gke-")):
            continue
        pod = d["spec"]["template"]["spec"]
        workloads.append({"namespace": ns, "name": d["metadata"]["name"], "kind": d["kind"],
            "serviceAccount": pod.get("serviceAccountName", "default"),
            "containers": [{"name": c["name"], "image": c["image"], "resources": c.get("resources", {})}
                           for c in pod.get("containers", [])], "status": d.get("status", {})})
    loadbalancers = [{"namespace": s["metadata"]["namespace"], "name": s["metadata"]["name"],
                     "annotations": {k: v for k, v in s["metadata"].get("annotations", {}).items() if
                                     k.startswith(("networking.gke.io/", "cloud.google.com/", "service.beta.kubernetes.io/"))},
                     "spec": s["spec"], "status": s.get("status", {})}
                    for s in security.get("service") if s["spec"]["type"] == "LoadBalancer"]
    resources = []
    for kind in ("gateway", "httproute", "listenersets", "agentgatewaybackend", "enterpriseagentgatewaypolicy",
                 "agentgatewaypolicy", "authorizationpolicy", "enterpriseagentgatewaybudget"):
        for r in security.get(kind):
            resources.append({"apiVersion": r["apiVersion"], "kind": r["kind"], "metadata": {
                "name": r["metadata"]["name"], "namespace": r["metadata"]["namespace"],
                "labels": r["metadata"].get("labels", {})}, "spec": r["spec"]})
    inventory = {"capturedAt": datetime.now(timezone.utc).isoformat(), "project": project, "cloud": cloud,
                 "helm": releases, "workloads": workloads, "loadBalancers": loadbalancers,
                 "routingAndSecurity": resources,
                 "nodes": [{"name": n["metadata"]["name"], "version": n["status"]["nodeInfo"]["kubeletVersion"],
                            "machine": n["metadata"]["labels"].get("node.kubernetes.io/instance-type"),
                            "capacity": n["status"]["capacity"]} for n in security.get("nodes")],
                 "storage": [{"namespace": p["metadata"]["namespace"], "name": p["metadata"]["name"],
                              "class": p["spec"].get("storageClassName"), "capacity": p.get("status", {}).get("capacity"),
                              "phase": p.get("status", {}).get("phase")} for p in security.get("pvc")]}
    args.output.write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
    print(f"Captured {len(releases)} releases, {len(workloads)} workloads, {len(loadbalancers)} LBs, {len(resources)} routing/security resources -> {args.output}")


if __name__ == "__main__":
    main()
