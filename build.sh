#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="gateway-api"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${ROOT_DIR}/VERSION" | tr -d '[:space:]')"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/.build/${PACKAGE_NAME}-${VERSION}"
PAYLOAD_DIR="${BUILD_DIR}/payload"
PAYLOAD_TAR="${BUILD_DIR}/payload.tar.gz"
RUN_NAME="${PACKAGE_NAME}-${VERSION}.run"
RUN_PATH="${DIST_DIR}/${RUN_NAME}"
BASE_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v${VERSION}"

usage() {
  cat <<USAGE
Usage: bash build.sh [options]

Build a Gateway API CRD-only offline .run installer package.

Options:
  --version <version>     Gateway API version without leading v. Default: ${VERSION}
  --base-url <url>        Override release asset base URL.
  --use-local-assets      Use assets already placed under upstream/ instead of downloading.
  -h, --help             Show this help.

Expected release assets:
  standard-install.yaml
  experimental-install.yaml
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

USE_LOCAL_ASSETS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"; shift 2 ;;
    --base-url)
      BASE_URL="${2:-}"; shift 2 ;;
    --use-local-assets)
      USE_LOCAL_ASSETS=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${VERSION}" ]] || die "version cannot be empty"
if [[ "${BASE_URL}" == *"/v"* ]]; then
  :
else
  BASE_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v${VERSION}"
fi

RUN_NAME="${PACKAGE_NAME}-${VERSION}.run"
RUN_PATH="${DIST_DIR}/${RUN_NAME}"
BUILD_DIR="${ROOT_DIR}/.build/${PACKAGE_NAME}-${VERSION}"
PAYLOAD_DIR="${BUILD_DIR}/payload"
PAYLOAD_TAR="${BUILD_DIR}/payload.tar.gz"

need tar
need sha256sum
if [[ "${USE_LOCAL_ASSETS}" != "1" ]]; then
  need curl
fi

[[ -f "${ROOT_DIR}/install.sh" ]] || die "install.sh not found"
grep -qx '__PAYLOAD_BELOW__' "${ROOT_DIR}/install.sh" || die "install.sh must contain a standalone __PAYLOAD_BELOW__ marker"
bash -n "${ROOT_DIR}/install.sh"

rm -rf "${BUILD_DIR}"
mkdir -p "${PAYLOAD_DIR}/manifests" "${PAYLOAD_DIR}/images" "${PAYLOAD_DIR}/meta" "${DIST_DIR}"

fetch_asset() {
  local file="$1"
  local dest="${PAYLOAD_DIR}/manifests/${file}"
  if [[ "${USE_LOCAL_ASSETS}" == "1" ]]; then
    [[ -f "${ROOT_DIR}/upstream/${file}" ]] || die "missing local asset: upstream/${file}"
    cp "${ROOT_DIR}/upstream/${file}" "${dest}"
  else
    local url="${BASE_URL%/}/${file}"
    echo ">>> downloading ${url}"
    curl -fL --retry 5 --retry-delay 3 -o "${dest}" "${url}"
  fi
  grep -q 'kind: CustomResourceDefinition' "${dest}" || die "${file} does not look like a CRD manifest"
}

fetch_asset standard-install.yaml
fetch_asset experimental-install.yaml

cat > "${PAYLOAD_DIR}/images/image-index.tsv" <<'EOF'
name|tar_name|load_ref|default_target_ref|platform|pull|dockerfile
EOF
cp "${ROOT_DIR}/images/image.json" "${PAYLOAD_DIR}/images/image.json"

cat > "${PAYLOAD_DIR}/meta/package.env" <<META
PACKAGE_NAME=${PACKAGE_NAME}
VERSION=${VERSION}
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STANDARD_ASSET=${BASE_URL%/}/standard-install.yaml
EXPERIMENTAL_ASSET=${BASE_URL%/}/experimental-install.yaml
META

cat > "${PAYLOAD_DIR}/meta/manifest-index.tsv" <<'EOF'
channel|file|apply_mode
standard|standard-install.yaml|server-side
experimental|experimental-install.yaml|server-side
EOF

(cd "${PAYLOAD_DIR}" && tar -czf "${PAYLOAD_TAR}" .)
tar -tzf "${PAYLOAD_TAR}" >/dev/null
cat "${ROOT_DIR}/install.sh" "${PAYLOAD_TAR}" > "${RUN_PATH}"
chmod +x "${RUN_PATH}"
(cd "${DIST_DIR}" && sha256sum "${RUN_NAME}" > "${RUN_NAME}.sha256")

echo ">>> wrote ${RUN_PATH}"
echo ">>> wrote ${RUN_PATH}.sha256"
ls -lh "${RUN_PATH}" "${RUN_PATH}.sha256"
