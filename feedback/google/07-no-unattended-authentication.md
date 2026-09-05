# 07 — No unattended authentication path: every credential requires an interactive browser

**Severity:** major
**Area:** IAM
**Date raised:** 2026-09-05
**Status:** open

## What we tried

Berlin preview, `eu0:soloio-eval`, universe `apis-berlin-build0.goog`,
gcloud active configuration `berlin`. We needed a credential that a deployment
script can renew on its own, because standing the platform up end to end takes
longer than one token lives.

Four candidate paths, tested in order.

**1. Service account key.**

```
$ gcloud iam service-accounts create hl-test --display-name="headless auth test"
Created service account [hl-test].
$ gcloud iam service-accounts keys create /tmp/hl-test-key.json \
    --iam-account=hl-test@soloio-eval.eu0.iam.gserviceaccount.com
```

**2. The organisation policies behind that.**

```
$ gcloud org-policies describe iam.disableServiceAccountKeyCreation \
    --organization=560780939237871 --effective
$ gcloud org-policies describe iam.disableServiceAccountKeyUpload \
    --organization=560780939237871 --effective
```

**3. Workforce-pool credential configuration** (file-sourced OIDC, the
documented non-interactive shape):

```
$ gcloud iam workforce-pools create-cred-config \
    "locations/global/workforcePools/preview-soloio-p/providers/preview-soloio-pp" \
    --output-file=/tmp/wf-cred.json \
    --workforce-pool-user-project=eu0:soloio-eval \
    --credential-source-file=/tmp/oidc-token
```

**4. Direct refresh of the WIF credential**, HTTP Basic client auth against
`token_url` from `application_default_credentials.json`.

## What happened

**1. Key creation is refused.**

```
ERROR: (gcloud.iam.service-accounts.keys.create) FAILED_PRECONDITION: Key creation is not allowed on this service account.
- '@type': type.googleapis.com/google.rpc.PreconditionFailure
  violations:
  - description: Key creation is not allowed on this service account.
    subject: projects/eu0:soloio-eval/serviceAccounts/hl-test@soloio-eval.eu0.iam.gserviceaccount.com?configvalue=hl-test%40soloio-eval.eu0.iam.gserviceaccount.com
    type: constraints/iam.disableServiceAccountKeyCreation
```

**2. Both key constraints are enforced org-wide, and we did not set them.**

```
name: organizations/560780939237871/policies/iam.disableServiceAccountKeyCreation
spec:
  rules:
  - enforce: true

name: organizations/560780939237871/policies/iam.disableServiceAccountKeyUpload
spec:
  rules:
  - enforce: true
```

**3. `create-cred-config` announces that it is unavailable, then works.**

```
INFORMATION
    gcloud iam workforce-pools create-cred-config is not available in universe
    domain apis-berlin-build0.goog.
```

It nonetheless wrote a well-formed configuration:

```json
{
    "universe_domain": "apis-berlin-build0.goog",
    "type": "external_account",
    "audience": "//iam.googleapis.com/locations/global/workforcePools/preview-soloio-p/providers/preview-soloio-pp",
    "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
    "token_url": "https://sts.apis-berlin-build0.goog/v1/token",
    "credential_source": { "file": "/tmp/oidc-token" },
    "workforce_pool_user_project": "eu0:soloio-eval",
    "token_info_url": "https://sts.apis-berlin-build0.goog/v1/introspect"
}
```

So the *mechanism* is present. What is missing is any way to obtain the
`id_token` it reads: the only identity provider in the pool is the operator's
bootstrap IdP `id-berlin-build0.goog`, which issues tokens only through an
interactive browser authorisation-code flow.

**4. Refreshing works, and tells us the window.**

```
refresh OK (HTTP Basic client auth)
  access token expires_in: 3381s (56 min)
  rotated refresh_token: no
```

Access tokens renew fine and gcloud does it automatically. The refresh token
itself has a shorter life than a working day, and when it lapses the failure is:

```
ERROR: (gcloud.config.config-helper) There was a problem refreshing your current auth tokens:
('Error code invalid_grant: Refresh token has expired',
 '{"error":"invalid_grant","error_description":"Refresh token has expired"}')
```

Net effect: **there is no credential in Berlin that a machine can renew.** Every
path terminates at a human and a browser.

## Why it matters for an ISV

This is the difference between a product an ISV can ship on and one they can
only demo on.

Our platform install is a 21-phase chain: infrastructure, an Autopilot cluster,
a ~20 minute cluster update to authorise privileged-workload allowlists, an
Istio ambient install, then the Solo agentic stack. It runs longer than one
credential lives. During this evaluation the chain died mid-way through the
allowlist cluster update and could not resume for six hours, because the only
person who could re-authenticate was away from the keyboard. That is a
deployment that cannot be automated, and it is the ordinary case, not an
edge case.

Downstream, the same gap removes:

- **CI/CD.** No GitHub Actions, GitLab or Cloud Build identity can reach GCD.
  There is no key to store and no federation path from outside the universe.
- **Unattended operations.** Nightly rebuilds, drift detection, scheduled
  Terraform, backup verification — anything on a timer.
- **Any managed-service or SaaS control plane** that reconciles a customer's GCD
  project on their behalf. That includes ours.

For a sovereign buyer this also cuts against the stated goal. Shared human
credentials with no machine identity means automation gets performed under a
person's account, which is worse for audit attribution than a service identity
would be — and attribution is precisely what this class of customer is buying.

We understand blocking long-lived exported keys; that is a defensible posture
and most mature customers are moving away from them. The problem is that
nothing has replaced them here.

## What would unblock us

Any one of these, in our order of preference:

1. **Allow workforce-pool federation of a customer's own OIDC provider that
   supports non-interactive grants**, and confirm the STS endpoint can reach an
   issuer's JWKS. The `external_account` file-sourced configuration already
   works — only the token source is missing. This is the smallest change.
2. **Service account impersonation from a workload identity outside the
   universe**, i.e. the standard `--impersonate-service-account` pattern with a
   federated CI identity as the caller.
3. **A scoped exception to `iam.disableServiceAccountKeyCreation`** for
   designated deployment service accounts, ideally with short-lived or
   auto-rotating keys.
4. Failing all of the above, **document the intended unattended-automation
   pattern for GCD**, because we could not find one and currently believe none
   exists.

Separately and cheaply: `gcloud iam workforce-pools create-cred-config` should
not print "is not available in universe domain apis-berlin-build0.goog" and then
succeed. Either it is supported or it is not; as it stands the message causes an
ISV to abandon the one path that is closest to working.
