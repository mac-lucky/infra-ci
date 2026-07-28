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

OpenTofu, sops, age, the 1Password CLI, bun, python3, and the usual
jq/git/curl on top of node 22.

Everything here has a caller, or a stated break-glass reason. `bun` builds the
Cloudflare worker bundles that `tofu plan` needs but the repo does not carry;
`python3` runs the destroy guard that gates auto-apply; `node` is there because
forgejo-runner does not supply one and `actions/checkout` is a JavaScript
action. `sops` and `age` are the break-glass pair: nothing shells out to either
(the SOPS provider reads the key through a library), but the repo's whole
secret story is SOPS/age and a debug job that cannot decrypt during an incident
is worth more than the 50 MB.

The image used to carry kubectl, helm, kustomize, kubeconform and talosctl for
a manifest-validation job that was never built. Nothing referenced them, so
they were removed rather than left to rot - `talosctl` in particular, whose
client has to match the running node version, which a weekly-rebuilt floating
image cannot promise.

## Build

Weekly, 04:00 Monday, plus on push and on demand. There is no upstream project
to track, so the schedule exists to pick up base image and package updates
rather than to follow a release.

Every downloaded binary is checked against the upstream SHA256 list before it
lands in the image; a tampered or truncated artifact fails the build. `age`
comes from Alpine instead, because upstream publishes sigsum proofs rather than
a checksum list and apk verifies package signatures itself.

The 1Password CLI is the one download with no checksum manifest at its CDN
path. It ships a detached signature inside the zip instead, verified with
`gpgv` against the committed `1password.asc`. The fingerprint that key must
have is pinned as `OP_GPG_FINGERPRINT` in the Dockerfile, which is the only
place it is asserted - it is deliberately not restated here, so a rotation
cannot leave this file quoting a fingerprint nothing checks.
That is a stronger check than a checksum: a checksum only proves the file
matches a list served from the same host, a signature proves 1Password produced
it. The key is committed rather than fetched from a keyserver so the build does
not depend on the network for it, and the Dockerfile asserts its fingerprint so
editing that file fails the build instead of quietly changing who is trusted.

Nothing in the image is now installed unverified.

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
