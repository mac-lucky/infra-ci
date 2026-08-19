# Job container image for Forgejo Actions in the infrastructure repo.
#
# Forgejo resolves a bare `uses: actions/foo` against DEFAULT_ACTIONS_URL rather
# than github.com, so every extra action is a mirroring problem. Baking the
# toolchain in means workflows need one action (checkout) and plain run steps
# for everything else.
#
# Node comes from the base image on purpose: forgejo-runner does not inject a
# node runtime the way GitHub's runner does, so a JavaScript action such as
# actions/checkout fails on an image without it.
#
# Everything here has a caller, or a stated break-glass reason (sops and age -
# see their notes below). The image used to carry kubectl, helm, kustomize,
# kubeconform and talosctl for a manifest-validation job that was never built;
# nothing referenced them but the smoke test that checked they existed, and no
# provider shells out to any of them. They were dropped rather than left to rot
# - talosctl especially, whose client has to match the running node version,
# which a floating image rebuilt on its own schedule cannot promise.
#
# The base tag deliberately floats. Every merged change to this Dockerfile or
# .grype-ignore.yaml tags a release (auto-tag.yml), and the build is gated on
# a Grype scan, so a pinned digest would freeze known-bad base layers in place
# instead of picking up fixes.

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS fetch

# Version pins live immediately above the RUN that consumes them, not in a
# block up here. Every in-scope ARG enters the exec environment of a shell-form
# RUN - BuildKit cannot know which ones the shell will dereference - so it folds
# all of them into that instruction's cache key. Declared together, editing the
# op pin alone re-downloads and re-verifies tofu, sops and bun too, roughly
# 116 MB per architecture. Measured, not assumed.
#
# TARGETARCH is the exception: every RUN below genuinely uses it.
#
# It has no default, deliberately. BuildKit injects the real value per platform,
# and a default here wins instead, which silently baked amd64 binaries into the
# arm64 image (which then failed with "syntax error" on running an x86 ELF).
ARG TARGETARCH

# gnupg/gpgv are for the op signature check and never reach the runtime stage.
# No tar: every fetch below is a zip or a bare binary now that the three
# tarball-shipped tools are gone.
RUN apk add --no-cache ca-certificates curl gnupg gpgv unzip

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

WORKDIR /work
RUN mkdir -p /out

# Fetch a file and check it against an upstream checksum list. Every checksummed
# download below goes through this, so a tampered or truncated artifact fails
# the build rather than ending up in the image. op is the exception - it has no
# checksum manifest and is verified by signature instead, see the block below.
#
# $1 url, $2 output path, $3 checksum list url, $4 name to match in that list.
COPY --chmod=0755 <<'EOF' /usr/local/bin/fetch-verify
#!/bin/ash
set -eu
url=$1; out=$2; sums=$3; name=$4
curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$out"
curl -fsSL --retry 3 --retry-delay 2 "$sums" -o /tmp/sums.txt
# $name goes into an ERE, so escape it: an unescaped "." matches any
# character and a sums file listing two similar filenames would match both.
esc=$(printf '%s' "$name" | sed 's/[].[^$*\\/]/\\&/g')
# `|| true` because grep -c exits 1 on zero matches, and under `set -e` that
# kills the script here - failing closed, but silently, with the diagnostic
# below never printed. Verified: without it a renamed upstream artifact gives
# a bare exit 1 and no clue why.
hits=$(grep -cE "[[:space:]]\*?${esc}$" /tmp/sums.txt || true)
if [ "$hits" -ne 1 ]; then
  echo "expected exactly 1 checksum line for $name, found $hits" >&2; exit 1
fi
want=$(grep -E "[[:space:]]\*?${esc}$" /tmp/sums.txt | awk '{print $1}')
if [ -z "$want" ]; then
  echo "no checksum for $name in $sums" >&2; exit 1
fi
got=$(sha256sum "$out" | awk '{print $1}')
if [ "$want" != "$got" ]; then
  echo "checksum mismatch for $name: want $want got $got" >&2; exit 1
fi
echo "verified $name"
EOF

# Each archive is removed in the RUN that created it. None of them reach the
# image, but the build cache is exported with mode=max, so a kept zip is dead
# weight on every cache round-trip - about 79 MB per architecture across the
# three downloads that use one.
ARG TOFU_VERSION=1.12.6
RUN set -eu; \
    B="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}"; \
    fetch-verify "$B/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip" tofu.zip \
                 "$B/tofu_${TOFU_VERSION}_SHA256SUMS" "tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip"; \
    unzip -q tofu.zip tofu -d /out; \
    rm -f tofu.zip

# Not needed by `tofu plan` - carlpett/sops reads secrets.enc.yaml through an
# embedded library, never this binary. It is here as break-glass: the whole
# secret story of the infrastructure repo is SOPS/age, and not being able to
# `sops -d` from a debug job during an incident costs more than the 50 MB.
ARG SOPS_VERSION=3.13.3
RUN set -eu; \
    B="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}"; \
    fetch-verify "$B/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" /out/sops \
                 "$B/sops-v${SOPS_VERSION}.checksums.txt" "sops-v${SOPS_VERSION}.linux.${TARGETARCH}"

# bun, for stacks whose plan needs a build artifact the repo does not carry
# (terraform/cloudflare bundles its workers with esbuild, and the committed
# lockfile is bun.lock). Not from apk: bun is not in Alpine stable. The musl
# build is required because the runtime stage is Alpine.
ARG BUN_VERSION=1.3.14
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) BUN_ARCH=x64 ;; \
      arm64) BUN_ARCH=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    B="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}"; \
    F="bun-linux-${BUN_ARCH}-musl.zip"; \
    fetch-verify "$B/$F" "$F" "$B/SHASUMS256.txt" "$F"; \
    unzip -q "$F"; \
    mv "bun-linux-${BUN_ARCH}-musl/bun" /out/; \
    rm -rf "$F" "bun-linux-${BUN_ARCH}-musl"

# 1Password publishes no SHA256 manifest at this CDN path, so op cannot go
# through fetch-verify. It ships op.sig *inside* the zip instead - a detached
# signature over the binary - which is a stronger check than a checksum anyway:
# a checksum only proves the file matches a list served from the same host, a
# signature proves 1Password produced it.
#
# The key is committed rather than pulled from a keyserver at build time. The
# point is to stop trusting the network for this artifact, and swapping one
# network dependency for another would not achieve that. The fingerprint
# assertion is what makes editing 1password.asc fail the build instead of
# quietly changing who is trusted.
#
# gpgv rather than `gpg --verify`: it has no trust model and no keyring of its
# own, so its exit code means "this signature is good" and nothing else. That
# cuts both ways - it also does no expiry or revocation checking - which is an
# acceptable trade only because exactly one fingerprint is pinned. The current
# key is valid to 2032-05-16; gpgv rejects signatures from an expired key, so
# the next release build will start failing loudly on that date rather than drifting.
#
# Note this diverges from both reference idioms: 1Password's own docs and the
# docker-library images fetch key bytes from a keyserver each build and pin only
# the fingerprint. Vendoring the key trades a build-time network trust
# dependency for a maintenance duty - if 1Password rotates, the build breaks
# until 1password.asc is re-synced, which is the safe direction.
#
# A signature alone does not bind the artifact to a VERSION, so the last step
# runs the binary and checks it. Without that, anyone able to serve this CDN
# path could hand back an older but genuinely-signed op - every check here
# would pass and the image would ship a known-vulnerable binary. Safe to
# execute at that point precisely because gpgv has already run.
#
# `unzip op op.sig` naming both members is also load-bearing: unzip exits 11 if
# either is absent, so were 1Password to stop shipping the signature the build
# would fail rather than quietly fall back to an unverified download. Verified.
#
# Last of the downloads on purpose - this COPY would otherwise invalidate the
# cached layers above it.
COPY 1password.asc /work/1password.asc

# Newest version published to cache.agilebits.com. The product history page
# lists releases ahead of the download CDN, so bump only after checking that
# the zip resolves.
ARG OP_VERSION=2.38.1
# "Code signing for 1Password" <codesign@1password.com>, asserted against the
# committed 1password.asc below.
ARG OP_GPG_FINGERPRINT=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
RUN set -eu; \
    # Count primary keys BEFORE trusting the fingerprint. --dearmor imports
    # every key in the file, so checking only the first fpr is not enough:
    # appending a second key to 1password.asc passes that check and still puts
    # the attacker in the keyring, after which gpgv accepts anything they sign.
    # Verified - the exploit works against the naive form. Subkeys of the
    # genuine key are fine and deliberately still allowed.
    pubs=$(gpg --show-keys --with-colons 1password.asc | grep -c '^pub:'); \
    if [ "$pubs" -ne 1 ]; then \
      echo "1password.asc must hold exactly one primary key, found $pubs" >&2; exit 1; \
    fi; \
    fpr=$(gpg --show-keys --with-colons 1password.asc | awk -F: '$1=="fpr"{print $10; exit}'); \
    if [ "$fpr" != "$OP_GPG_FINGERPRINT" ]; then \
      echo "1password.asc is $fpr, expected $OP_GPG_FINGERPRINT" >&2; exit 1; \
    fi; \
    gpg --dearmor < 1password.asc > 1password.gpg; \
    curl -fsSL --retry 3 --retry-delay 2 \
      "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_${TARGETARCH}_v${OP_VERSION}.zip" -o op.zip; \
    unzip -q op.zip op op.sig; \
    gpgv --keyring ./1password.gpg op.sig op; \
    chmod 0755 op; \
    got=$(./op --version); \
    if [ "$got" != "$OP_VERSION" ]; then \
      echo "signature is valid but this is op $got, expected $OP_VERSION" >&2; exit 1; \
    fi; \
    echo "verified op $OP_VERSION against $OP_GPG_FINGERPRINT"; \
    mv op /out/; \
    rm -f op.zip op.sig 1password.gpg


FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43

# age comes from Alpine rather than a release tarball: upstream publishes
# sigsum .proof files instead of a SHA256 list, and apk verifies package
# signatures itself, which is a stronger guarantee than an unverified download.
# Like sops it has no caller - the sops provider reads the key, not the binary -
# and is kept for the same break-glass reason.
#
# python3 runs scripts/plan_guard.py, the destroy guard on the auto-apply path.
# py3-jinja2 is for the ansible template tests in the infrastructure repo,
# which render Jinja2 templates outside of ansible itself.
RUN apk add --no-cache \
      age bash ca-certificates coreutils curl git jq openssh-client python3 py3-jinja2 tar unzip

# --chmod here instead of a RUN chmod in the fetch stage, which would
# rewrite every binary into an extra layer that mode=max exports to cache.
COPY --from=fetch --chmod=0755 /out/ /usr/local/bin/

# Fail the build here rather than discover a broken tool mid-pipeline.
RUN set -eux; \
    tofu version; sops --version; age --version; op --version; \
    node --version; bun --version; python3 --version; jq --version; git --version

WORKDIR /workspace
