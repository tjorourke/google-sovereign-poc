# 02 — The `eu0:` project prefix is not a legal container image reference

**Severity:** minor (was major — see the resolution note)
**Area:** Artifact Registry | docs
**Date raised:** 2026-09-03
**Status:** workaround — the product is fine, the documentation is not

## Summary

Every GCD project id carries a universe prefix ending in a colon — ours is `eu0:soloio-eval`. A
colon is not legal inside a path component of an OCI / Docker distribution reference, so any image
reference built the way Google's own documentation composes them
(`<host>/<project-id>/<repo>/<image>:<tag>`) is rejected by the client before a request is ever
sent. This affects `docker`, `containerd`/`crictl`, `crane`, and Helm's OCI client equally, because
they all implement the same grammar.

Artifact Registry is the only image path into GCD — there are no remote or virtual repositories, so
there is no pull-through mirror and an ISV must push every image explicitly. That makes the
reference format load-bearing.

## What we tried

Built a trivial image, then tagged it two ways. Docker 29.4.0, macOS, no GCD credentials needed —
the failure is entirely in the client-side reference parser.

```
$ docker tag gcd-mcp-test:local \
    u-germany-northeast1-docker.pkg-berlin-build0.goog/eu0:soloio-eval/solo/everything-server:latest

$ docker tag gcd-mcp-test:local \
    u-germany-northeast1-docker.pkg-berlin-build0.goog/soloio-eval/solo/everything-server:latest
```

## What happened

The prefixed form fails:

```
error parsing reference: "u-germany-northeast1-docker.pkg-berlin-build0.goog/eu0:soloio-eval/solo/everything-server:latest" is not a valid repository/tag: invalid reference format
```

The unprefixed control succeeds silently and the tag is created:

```
$ docker images --format '{{.Repository}}:{{.Tag}}' | grep berlin-build0
u-germany-northeast1-docker.pkg-berlin-build0.goog/soloio-eval/solo/everything-server:latest
```

Full transcript with versions:
`feedback/google/evidence/berlin-eu0-colon-docker-ref-2026-09-03.txt`

## Why it happens

The distribution reference grammar permits a colon in exactly two positions: in the registry host,
where it delimits a port, and after the final path component, where it delimits the tag. A path
component is `[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*` — no colon. `eu0:soloio-eval` is therefore not a
legal path component and the reference is rejected as a whole.

## Why it matters for an ISV

Onboarding a container-based ISV to GCD begins with pushing images. Three consequences:

1. **The documented project-id convention cannot be used in an image reference.** Every place our
   tooling composes `<host>/<project>/<repo>` — build scripts, Helm values, Kubernetes manifests,
   CI pipelines — has to special-case GCD by stripping a prefix that Google's docs say is
   mandatory everywhere else. `/docs/overview/tpc-key-differences` states that project IDs are
   "always used with their universe-specific prefix, including in the console and when specifying
   the project in commands and API calls", with one documented exception (service account names).
   Container references are a second exception and are not documented as one.
2. **The failure is opaque.** `invalid reference format` names no project, no registry and no
   prefix. An engineer following the docs will read it as a typo in their own script. We lost time
   to it and we already knew the colon was a hazard.
3. **It compounds with the absence of a pull-through mirror.** Because GCD has no remote or virtual
   repositories, there is no path that avoids hand-constructing image references, so there is no
   way to route around this.

Since Artifact Registry supports Docker, Apt and Yum formats and lists `helm` nowhere in its
supported clients, OCI-Helm packaging may hit the same wall; we have not been able to confirm that
yet.

## What would unblock us

Any one of these, in order of preference:

1. **Document the exception explicitly.** Add container image references to the list of places the
   universe prefix is *not* used, alongside service account names, in
   `/docs/overview/tpc-key-differences` and in the Artifact Registry differences page, and make
   `gcloud artifacts repositories describe --format='value(registryUri)'` the documented way to get
   a usable reference. This is a docs change and would have saved us the whole investigation.
2. **Make `registryUri` authoritative and prefix-free**, and say so on the differences page, so
   tooling has one API-derived value to trust rather than a composition rule with an undocumented
   exception.
3. **Longer term: reconsider the colon.** A universe prefix delimited by something DNS- and
   OCI-safe (`eu0-soloio-eval`, or a hyphen) would remove this class of problem entirely rather
   than adding an exception to it. We appreciate that is a larger change; items 1 and 2 are what we
   actually need.

## Resolution, once we could create a repository

Artifact Registry solves this correctly, and neither of our two guesses was right. The API reports:

```
$ gcloud artifacts repositories describe solo --location u-germany-northeast1 --project eu0:soloio-eval
name:        projects/eu0:soloio-eval/locations/u-germany-northeast1/repositories/solo
registryUri: docker.pkg-berlin-build0.goog/eu0/soloio-eval/solo
```

Two things to note:

1. **The universe prefix becomes its own path segment**: `eu0/soloio-eval`, not `eu0:soloio-eval`.
   That is a legal docker reference and we verified it parses. So the product is not broken —
   composing the reference by substituting the project id is what breaks.
2. **There is no `<region>-docker` host prefix.** Public GCP uses
   `<region>-docker.pkg.dev`; GCD uses a bare `docker.pkg-berlin-build0.goog`. We had assumed the
   regional prefix carried over and it does not, so even a caller who handled the colon correctly
   would have built the wrong host.

So this downgrades from a product blocker to a **documentation gap**, but the gap is still real and
still cost us time. The remaining ask is item 1 below, narrowed:

**Document the reference format.** State on the Artifact Registry differences page that the
universe prefix appears as a separate path segment (`eu0/soloio-eval`) and that the host has no
regional prefix, and point readers at
`gcloud artifacts repositories describe --format='value(registryUri)'` as the authoritative source.
One paragraph and one example would have removed the entire investigation. `/docs/overview/tpc-key-differences`
currently says project IDs are "always used with their universe-specific prefix, including in the
console and when specifying the project in commands and API calls", with service account names as
the single documented exception. Container references are a second exception, in a third form.

## Unrelated observation from the same output

The repository reports a `vulnerabilityScanningConfig` with a `lastEnableTime`, while
`/artifact-registry/docs/tpc-differences` states "Vulnerability scanning with Artifact Analysis
isn't available." Worth asking which is correct, since `containeranalysis` is absent from the
service catalogue. Not blocking us.
