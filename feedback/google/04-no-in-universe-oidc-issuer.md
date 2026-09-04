# 04 — There is no in-universe OIDC issuer for application workloads

**Severity:** major
**Area:** IAM | ISV onboarding
**Date raised:** 2026-09-03
**Status:** open

## Summary

GCD provides no identity service an application can use as its OIDC issuer. Workforce Identity
Federation solves human access to the console and API; it does not publish a discovery document and
JWKS that a workload can validate tokens against. Every Google product that would fill this role is
absent from the catalogue. An ISV therefore has to either self-host an issuer inside the universe or
depend on an external one — and for a sovereign customer the second option puts token issuance
outside the boundary they are paying to establish.

## What we tried

Looked for any identity service an application could point `oidc.issuer` at:

```
$ gcloud services list --available --project eu0:soloio-eval | grep -iE 'identity|iap|firebase'
```

## What happened

Nothing matched. Checked individually against the 31 available services:

```
identitytoolkit   (Identity Platform)      absent
cloudidentity                              absent
iap               (Identity-Aware Proxy)   absent
firebase                                   absent
secretmanager                              absent
```

For contrast, the products in our platform each require a standard OIDC issuer at install time —
for example the Solo Enterprise for kagent chart takes `oidc.issuer`, `oidc.clientId` and a client
secret, and its controller refuses to start without a discoverable issuer. AgentRegistry Enterprise
refuses to render at all without three OIDC values:

```
CHART CONFIGURATION ERROR:
oidc.issuer is required. AgentRegistry Enterprise requires an external OIDC identity provider.
oidc.clientId is required. AgentRegistry Enterprise requires the backend OIDC client ID.
oidc.publicClientId is required. AgentRegistry Enterprise requires the browser UI OIDC client ID.
```

We resolved it by deploying Keycloak 26.3 into the cluster as the issuer, with a Cloud DNS private
zone so that one issuer string (`http://keycloak.agentic.eu0.internal/realms/agentregistry`)
resolves identically in the browser and inside the cluster. That works, and OIDC discovery from a
pod returns the expected document. It is not a production answer.

## Why it matters for an ISV

**The workaround is a new production dependency.** Self-hosting Keycloak means we own its
availability, its database, its backup and restore, its upgrade path and its own TLS — inside a
universe that has no Secret Manager to hold its client secrets, no Certificate Manager to issue its
certificate, and no managed Postgres integration for it out of the box. That is a substantial
operational surface added purely because the platform has no issuer.

**The alternative undermines the sovereignty claim.** The other option is to point the products at
the customer's existing IdP, which for most German enterprises is Microsoft Entra ID or Okta —
both operated outside the sovereign boundary. Tokens authorising a workload inside a
partner-operated, physically isolated universe would then be minted in the public cloud, and the
availability of the sovereign workload's auth path would depend on a service outside the perimeter.
A customer's compliance team will ask about exactly this, and the honest answer today is that GCD
offers no way to avoid it.

**It is inconsistent with the rest of the identity story.** GCD went to real lengths to keep
identity external and customer-controlled — no Google Accounts, no Cloud Identity, Workforce
Identity Federation only. That is coherent for human access. But it leaves workload-to-workload and
user-to-application authentication with no in-universe primitive at all, which is the gap.

## What would unblock us

In rough order of preference:

1. **Make Workforce Identity Federation usable as an application issuer** — expose a standard OIDC
   discovery endpoint and JWKS for a workforce pool, so an application can validate the same tokens
   the console accepts. This would be the smallest change with the largest effect, because the
   customer's IdP is already federated and the trust chain already exists.
2. **Bring Identity Platform (`identitytoolkit`) into the catalogue.** It is the obvious existing
   product for this and would give ISVs a managed issuer inside the boundary.
3. **Failing either, document the expectation.** If self-hosting an issuer is the intended pattern,
   say so in the ISV onboarding material and name the reference implementation, so every ISV does
   not independently rediscover it and reach a different answer.

We would also value guidance on the sovereignty question itself: for a customer whose IdP is
outside the boundary, what is Google's recommended position on external token issuance for
in-universe workloads?
