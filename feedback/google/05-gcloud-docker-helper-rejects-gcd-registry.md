# 05 — `gcloud auth configure-docker` refuses the GCD Artifact Registry host

**Severity:** major
**Area:** Artifact Registry | gcloud CLI
**Date raised:** 2026-09-03
**Status:** workaround

## Summary

`gcloud auth configure-docker` and `docker-credential-gcloud` both validate the registry hostname
against a hardcoded allowlist that does not include GCD's Artifact Registry domain. The documented
way to authenticate Docker to Artifact Registry therefore does not work in a GCD universe, and the
failure is a warning rather than an error, so the subsequent `docker push` fails much later with an
unrelated-looking permissions message.

Pushing images is the first thing a container-based ISV does. This blocks it.

## What we tried

The repository exists and reports its own URI:

```
$ gcloud artifacts repositories describe solo --location u-germany-northeast1 --project eu0:soloio-eval
registryUri: docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo
```

So we configured Docker for that host, exactly as the Artifact Registry documentation prescribes:

```
$ gcloud auth configure-docker docker.pkg-berlin-build0.goog --quiet
```

## What happened

`configure-docker` reports success but writes no credential helper entry:

```
Adding credentials for: docker.pkg-berlin-build0.goog
WARNING: docker.pkg-berlin-build0.goog is not a supported registry
gcloud credential helpers already registered correctly.
```

`~/.docker/config.json` gains no `credHelpers` entry for the host. Asking the helper directly is an
outright error:

```
$ echo '{"ServerURL":"docker.pkg-berlin-build0.goog"}' | docker-credential-gcloud get
ERROR: (gcloud.auth.docker-helper) Repository url [docker.pkg-berlin-build0.goog] is not supported
```

The push then fails, and the message points at permissions rather than at authentication:

```
error from registry: Unauthenticated request. Unauthenticated requests do not have permission
"artifactregistry.repositories.uploadArtifacts" on resource
"projects/eu0:soloio-eval/locations/u-germany-northeast1/repositories/solo" (or it may not exist)
```

An engineer reading that will go and check IAM roles on the repository — which are correct — rather
than suspect that `configure-docker` silently did nothing. We did exactly that.

## The workaround

Basic auth with an access token works, and Artifact Registry accepts it:

```
$ gcloud auth print-access-token \
  | docker login -u oauth2accesstoken --password-stdin docker.pkg-berlin-build0.goog
Login Succeeded

$ docker push docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo/everything-server:latest
latest: digest: sha256:9dc85723dcacfcd87db71ecfb83c48e8695e28f164601f9359f8d8f5dab94089 size: 856
```

So the registry and the IAM grants are fine. Only the credential-helper path is broken.

One consequence worth noting: because the token is short-lived — and GCD's Workforce Identity
Federation tokens are notably short-lived, see finding 10 in our deployment record — this login has
to be refreshed far more often than a credential helper would need. Any build pipeline has to
re-login rather than rely on a helper.

## Why it matters for an ISV

**It blocks the first action of onboarding.** Before any Helm chart installs, an ISV has to get
images into the universe — and GCD has no remote or virtual Artifact Registry repositories, so
there is no pull-through mirror and no way to avoid pushing explicitly.

**The failure mode is misleading.** A warning that reads like a formality, followed minutes later by
a permissions error naming a real IAM permission, sends you to the wrong place. This cost us time
even though we already knew GCD hostnames differ from public Google Cloud.

**It affects every tool that shells out to the helper**, not just `docker` — `containerd`, `crane`,
`skopeo` and Helm's OCI client all use the same mechanism, so each needs its own token workaround.

## What would unblock us

1. **Add the universe Artifact Registry domain to the hostname allowlist** in
   `gcloud auth configure-docker` and `docker-credential-gcloud`. The domain is already known to
   gcloud from the active configuration's `universe_domain`, so it could be derived rather than
   listed.
2. **Failing that, make it an error rather than a warning**, and say what to do instead. A one-line
   pointer to the `oauth2accesstoken` login would have saved the whole investigation.
3. **Document the token login on the Artifact Registry differences page**, alongside the
   `registryUri` note we asked for in finding 08 of the deployment record.
