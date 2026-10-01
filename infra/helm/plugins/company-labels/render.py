#!/usr/bin/env python3
# Helm post-renderer, and a plain stdin->stdout filter for kubectl applies
# (label_apply in lib.sh): stamps COMPANY_LABEL_KEY=COMPANY_LABEL_VALUE on every
# rendered object and on every pod template inside it.
#
# Google's ask is that EVERY pod carries a company identifier. Each chart's own
# commonLabels/podLabels gets most of the way, but not all: kagent-enterprise
# 0.4.3 has no pod-label value for its controller, kmcp or tools Deployments,
# and management / agentregistry leave their ClickHouse and OTel collector pods
# bare. Rather than depend on what each chart happens to expose, label the
# rendered output. Selectors are never touched -- they are immutable on a live
# Deployment, and a label on the template alone is enough.
import os, sys, yaml

key = os.environ.get("COMPANY_LABEL_KEY", "company")
val = os.environ.get("COMPANY_LABEL_VALUE", "trustusbank")


def stamp(meta):
    if not isinstance(meta, dict):
        return
    labels = meta.get("labels") or {}
    labels[key] = val
    meta["labels"] = labels


def visit(obj):
    if not isinstance(obj, dict) or "kind" not in obj:
        return
    kind = obj["kind"]
    if kind.endswith("List") and isinstance(obj.get("items"), list):
        for i in obj["items"]:
            visit(i)
        return
    obj.setdefault("metadata", {})
    stamp(obj["metadata"])
    spec = obj.get("spec") or {}
    if kind == "CronJob":
        spec = ((spec.get("jobTemplate") or {}).get("spec")) or {}
    if isinstance(spec.get("template"), dict):
        spec["template"].setdefault("metadata", {})
        stamp(spec["template"]["metadata"])
    if kind == "Prometheus":  # prometheus-operator builds the pods from podMetadata
        spec.setdefault("podMetadata", {})
        stamp(spec["podMetadata"])
    # Objects whose pods a controller creates later, from a template in the CR.
    # Labelling the CR's own metadata does nothing for those pods.
    if kind in ("EnterpriseAgentgatewayParameters", "AgentgatewayParameters"):
        # spec.deployment is a strategic-merge overlay on the proxy Deployment:
        # metadata.labels -> the Deployment, spec.template.metadata.labels -> pods.
        dep = spec.setdefault("deployment", {})
        stamp(dep.setdefault("metadata", {}))
        tmpl = dep.setdefault("spec", {}).setdefault("template", {})
        stamp(tmpl.setdefault("metadata", {}))
    elif kind == "Gateway" and obj.get("apiVersion", "").startswith("gateway.networking.k8s.io"):
        # Gateway API's own hook: propagated to every generated resource.
        stamp(spec.setdefault("infrastructure", {}))
    elif kind == "MCPServer" and obj.get("apiVersion", "").startswith("kagent.dev"):
        stamp(spec.setdefault("deployment", {}))
    elif kind == "Agent" and obj.get("apiVersion", "").startswith("kagent.dev"):
        for branch in ("declarative", "byo"):
            if isinstance(spec.get(branch), dict):
                stamp(spec[branch].setdefault("deployment", {}))


docs = list(yaml.safe_load_all(sys.stdin))
for d in docs:
    visit(d)
yaml.safe_dump_all([d for d in docs if d is not None], sys.stdout,
                   default_flow_style=False, sort_keys=False)
