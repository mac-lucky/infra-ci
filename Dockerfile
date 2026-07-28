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
# The base tag deliberately floats. This image is rebuilt every Monday and the
# build is gated on a Grype scan, so a pinned digest would freeze known-bad
# base layers in place instead of picking up fixes.

FROM alpine:3.22 AS fetch

ARG TOFU_VERSION=1.12.5
ARG SOPS_VERSION=3.13.3
# Tracks scripts/k8s-versions.env in the Kubernetes repo (TALOS_K8S).
ARG KUBECTL_VERSION=1.36.3
# Stays on 3.x. Helm 4 exists, but ArgoCD's repo-server renders these charts
# with helm 3, and validating against a different major would let CI pass on
# output the cluster never sees.
ARG HELM_VERSION=3.21.3
ARG KUSTOMIZE_VERSION=5.8.1
ARG KUBECONFORM_VERSION=0.8.0
# Matches var.talos_version in terraform/talos.
ARG TALOSCTL_VERSION=1.13.6
# Newest version published to cache.agilebits.com. The product history page
# lists releases ahead of the download CDN, so bump only after checking that
# the zip resolves.
ARG OP_VERSION=2.35.0

# No default. BuildKit injects the real value per platform, and giving it a
# default here wins instead, which silently baked amd64 binaries into the arm64
# image (helm then failed as "syntax error" because it was an x86 ELF).
ARG TARGETARCH

RUN apk add --no-cache ca-certificates curl tar unzip

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

WORKDIR /work
RUN mkdir -p /out

# Fetch a file and check it against an upstream checksum list. Every download
# below goes through this, so a tampered or truncated artifact fails the build
# rather than ending up in the image.
#
# $1 url, $2 output path, $3 checksum list url, $4 name to match in that list.
# An empty $4 means the list holds a bare hash and nothing else (kubectl).
COPY <<'EOF' /usr/local/bin/fetch-verify
#!/bin/ash
set -eu
url=$1; out=$2; sums=$3; name=${4:-}
curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$out"
curl -fsSL --retry 3 --retry-delay 2 "$sums" -o /tmp/sums.txt
if [ -n "$name" ]; then
  want=$(grep -E "[[:space:]]\*?${name}$" /tmp/sums.txt | awk '{print $1}' | head -n1)
else
  want=$(tr -d '[:space:]' < /tmp/sums.txt)
fi
if [ -z "$want" ]; then
  echo "no checksum for ${name:-$out} in $sums" >&2; exit 1
fi
got=$(sha256sum "$out" | awk '{print $1}')
if [ "$want" != "$got" ]; then
  echo "checksum mismatch for ${name:-$out}: want $want got $got" >&2; exit 1
fi
echo "verified ${name:-$out}"
EOF
RUN chmod 0755 /usr/local/bin/fetch-verify

RUN set -eu; \
    B="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}"; \
    fetch-verify "$B/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip" tofu.zip \
                 "$B/tofu_${TOFU_VERSION}_SHA256SUMS" "tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip"; \
    unzip -q tofu.zip tofu -d /out

RUN set -eu; \
    B="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}"; \
    fetch-verify "$B/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" /out/sops \
                 "$B/sops-v${SOPS_VERSION}.checksums.txt" "sops-v${SOPS_VERSION}.linux.${TARGETARCH}"

RUN set -eu; \
    B="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}"; \
    fetch-verify "$B/kubectl" /out/kubectl "$B/kubectl.sha256"

RUN set -eu; \
    F="helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    fetch-verify "https://get.helm.sh/$F" "$F" "https://get.helm.sh/${F}.sha256sum" "$F"; \
    tar xzf "$F"; mv "linux-${TARGETARCH}/helm" /out/

RUN set -eu; \
    B="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}"; \
    F="kustomize_v${KUSTOMIZE_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    fetch-verify "$B/$F" "$F" "$B/checksums.txt" "$F"; \
    tar xzf "$F" -C /out kustomize

RUN set -eu; \
    B="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}"; \
    F="kubeconform-linux-${TARGETARCH}.tar.gz"; \
    fetch-verify "$B/$F" "$F" "$B/CHECKSUMS" "$F"; \
    tar xzf "$F" -C /out kubeconform

RUN set -eu; \
    B="https://github.com/siderolabs/talos/releases/download/v${TALOSCTL_VERSION}"; \
    fetch-verify "$B/talosctl-linux-${TARGETARCH}" /out/talosctl \
                 "$B/sha256sum.txt" "talosctl-linux-${TARGETARCH}"

# The only download with no upstream checksum list. 1Password publishes the zip
# and a detached signature but no plain SHA256 manifest at this CDN path, so
# this one rests on TLS alone. Revisit if they start publishing one.
RUN set -eu; \
    curl -fsSL --retry 3 --retry-delay 2 \
      "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_linux_${TARGETARCH}_v${OP_VERSION}.zip" -o op.zip; \
    unzip -q op.zip op -d /out

RUN chmod 0755 /out/*


FROM node:22-alpine

# age comes from Alpine rather than a release tarball: upstream publishes
# sigsum .proof files instead of a SHA256 list, and apk verifies package
# signatures itself, which is a stronger guarantee than an unverified download.
RUN apk add --no-cache \
      age bash ca-certificates coreutils curl git jq openssh-client tar unzip yq

COPY --from=fetch /out/ /usr/local/bin/

# helm-secrets, so `helm template` can read the SOPS-encrypted valueFiles the
# Kubernetes repo uses (secrets://secrets.yaml). Pinned to the version the
# ArgoCD repo-server installs so rendering here matches the cluster.
ARG HELM_SECRETS_VERSION=4.7.6
ENV HELM_PLUGINS=/usr/local/share/helm/plugins
RUN helm plugin install https://github.com/jkroepke/helm-secrets --version "v${HELM_SECRETS_VERSION}" \
    && rm -rf /root/.cache

# Fail the build here rather than discover a broken tool mid-pipeline.
RUN set -eux; \
    tofu version; sops --version; age --version; kubectl version --client=true; \
    helm version --short; kustomize version; kubeconform -v; talosctl version --client; \
    op --version; node --version; jq --version; yq --version; git --version

WORKDIR /workspace
