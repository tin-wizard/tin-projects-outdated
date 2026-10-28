#!/usr/bin/env bash
# Build the TIN Projects images with the upstream rush docker pipeline, then tag them
# as $TIN_REGISTRY/tin-projects-<service>:$TIN_VERSION. Run from anywhere, with Node 22.
#   TIN_VERSION=v0.7.426-tin.1 tin/selfhost/build-images.sh          # build + tag locally
#   TIN_VERSION=v0.7.426-tin.1 tin/selfhost/build-images.sh --push   # also push (needs registry login)
# Platform defaults to the host's; set DOCKER_EXTRA=--platform=linux/amd64 for x86 servers.
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${TIN_VERSION:?set TIN_VERSION, e.g. v0.7.426-tin.1}"
REGISTRY="${TIN_REGISTRY:-ghcr.io/tin-wizard}"
export DOCKER_VERSION="$TIN_VERSION" DOCKER_BUILDKIT=1 DOCKER_CLI_HINTS=false

# upstream image name -> rush project
declare -a IMAGES=(
  "front:@hcengineering/pod-front"
  "account:@hcengineering/pod-account"
  "transactor:@hcengineering/pod-server"
  "workspace:@hcengineering/pod-workspace"
  "collaborator:@hcengineering/pod-collaborator"
  "fulltext:@hcengineering/pod-fulltext"
  "stats:@hcengineering/pod-stats"
  "mail:@hcengineering/pod-mail"
  "rekoni-service:@hcengineering/rekoni-service"
)

RUSH="node common/scripts/install-run-rush.js"
TO_ARGS=()
for entry in "${IMAGES[@]}"; do TO_ARGS+=(--to "${entry#*:}"); done

$RUSH install
$RUSH model-version
$RUSH docker:build -v "${TO_ARGS[@]}"

for entry in "${IMAGES[@]}"; do
  name="${entry%%:*}"
  target="$REGISTRY/tin-projects-${name%-service}:$TIN_VERSION"
  docker tag "hardcoreeng/$name:$TIN_VERSION" "$target"
  echo "tagged $target"
  if [ "${1:-}" = "--push" ]; then docker push "$target"; fi
done
