# infra-ci

Job container image for Forgejo Actions in the `infrastructure` repo.

`ghcr.io/mac-lucky/infra-ci:latest`

## Why it exists

Forgejo resolves a bare `uses: actions/foo` against its `DEFAULT_ACTIONS_URL`
(`data.forgejo.org`) rather than github.com, so every extra action a workflow
pulls is a mirroring problem. Baking the toolchain into the job image means a
workflow needs one action, `checkout`, and plain `run:` steps for everything
else.

## Contents

OpenTofu, sops, age, kubectl, helm 3 (plus helm-secrets), kustomize,
kubeconform, talosctl, the 1Password CLI, and the usual jq/yq/git/curl.

Helm stays on 3.x because ArgoCD's repo-server renders the manifests with helm
3; validating against helm 4 would let CI pass on output the cluster never
sees. `kubectl` tracks `scripts/k8s-versions.env` in the Kubernetes repo, and
`talosctl` matches `var.talos_version` in `terraform/talos`.

## Build

Weekly, 04:00 Monday, plus on push and on demand. There is no upstream project
to track, so the schedule exists to pick up base image and package updates
rather than to follow a release.

Every downloaded binary is checked against the upstream SHA256 list before it
lands in the image; a tampered or truncated artifact fails the build. `age`
comes from Alpine instead, because upstream publishes sigsum proofs rather than
a checksum list and apk verifies package signatures itself. The one exception
is the 1Password CLI, which has no published checksum manifest at its CDN path
and so rests on TLS alone.

The base tag floats deliberately. The build is gated on a Grype scan at `high`
and above, so a pinned digest would hold known-bad base layers in place instead
of picking up fixes.

Built for `linux/amd64` and `linux/arm64`.

The bundled tools are upstream release binaries, so the Go stdlib and modules
compiled into them are whatever those projects shipped. Those cannot be patched
here; a fix arrives when the project cuts a release, which the weekly rebuild
picks up. They are covered by location-scoped entries in the org Grype baseline
(`actions-shared-workflows/security/grype-base-policy.yaml`) so the gate still
catches everything else.
