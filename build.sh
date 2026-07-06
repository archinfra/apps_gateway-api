#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="gateway-api"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
VERSION="${DEFAULT_VERSION}"
ARCH="all"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_ROOT="${ROOT_DIR}/.build"
BASE_URL=""
USE_LOCAL_ASSETS=0
KEEP_BUILD=0

ASSETS=(standard-install.yaml experimental-install.yaml)

usage() {
  cat <<USAGE
Usage: bash build.sh [options]

Build Gateway API CRD-only offline .run installer packages.

Options:
  --arch <amd64|arm64|all>  Target installer architecture label. Default: all.
  --version <version>       Gateway API version without leading v. Default: ${VERSION}
  --base-url <url>          Override release asset base URL.
  --use-local-assets        Use assets already placed under upstream/ instead of downloading.
  --keep-build              Keep .build/ working directories after packaging.
  -h, --help                Show this help.

Expected release assets:
  upstream/standard-install.yaml
  upstream/experimental-install.yaml

Notes:
  Gateway API is a CRD-only package here, so no Docker, Helm, jq, or Python is required.
  The CRDs are architecture-independent, but this build emits amd64/arm64 .run files so
  release artifacts can match normal offline delivery conventions.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="${2:-}"; shift 2 ;;
    --version)
      VERSION="${2:-}"; shift 2 ;;
    --base-url)
      BASE_URL="${2:-}"; shift 2 ;;
    --use-local-assets)
      USE_LOCAL_ASSETS=1; shift ;;
    --keep-build)
      KEEP_BUILD=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

VERSION="${VERSION#v}"
[[ -n "${VERSION}" ]] || die "version cannot be empty"
case "${ARCH}" in amd64|arm64|all) ;; *) die "--arch must be amd64, arm64, or all" ;; esac
if [[ -z "${BASE_URL}" ]]; then
  BASE_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v${VERSION}"
fi

need tar
need sha256sum
if [[ "${USE_LOCAL_ASSETS}" != "1" ]]; then
  need curl
fi

[[ -f "${ROOT_DIR}/install.sh" ]] || die "install.sh not found"
[[ -f "${ROOT_DIR}/images/image.json" ]] || die "images/image.json not found"
marker_count="$(grep -cx '__PAYLOAD_BELOW__' "${ROOT_DIR}/install.sh" || true)"
[[ "${marker_count}" == "1" ]] || die "install.sh must contain exactly one standalone __PAYLOAD_BELOW__ marker"
bash -n "${ROOT_DIR}/install.sh"

case "$(tr -d '[:space:]' < "${ROOT_DIR}/images/image.json")" in
  "[]") ;;
  *) die "Gateway API package is CRD-only; images/image.json must be an empty JSON array" ;;
esac

arch_list() {
  case "${ARCH}" in
    all) printf '%s\n' amd64 arm64 ;;
    *) printf '%s\n' "${ARCH}" ;;
  esac
}

platform_for_arch() {
  case "$1" in
    amd64) printf '%s\n' linux/amd64 ;;
    arm64) printf '%s\n' linux/arm64 ;;
    *) die "unsupported arch: $1" ;;
  esac
}

validate_asset() {
  local file="$1"
  grep -q 'kind:[[:space:]]*CustomResourceDefinition' "${file}" || die "${file} does not look like a CRD manifest"
  grep -q 'gateway.networking' "${file}" || die "${file} does not look like a Gateway API manifest"
}

prepare_assets() {
  local cache_dir="${BUILD_ROOT}/upstream-${VERSION}"
  rm -rf "${cache_dir}"
  mkdir -p "${cache_dir}"

  local asset src url dest
  for asset in "${ASSETS[@]}"; do
    dest="${cache_dir}/${asset}"
    if [[ "${USE_LOCAL_ASSETS}" == "1" ]]; then
      src="${ROOT_DIR}/upstream/${asset}"
      [[ -f "${src}" ]] || die "missing local asset: upstream/${asset}"
      cp "${src}" "${dest}"
    else
      url="${BASE_URL%/}/${asset}"
      info "downloading ${url}"
      curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -o "${dest}" "${url}"
    fi
    validate_asset "${dest}"
  done
  printf '%s\n' "${cache_dir}"
}

write_image_index() {
  local dest="$1"
  cat > "${dest}" <<'INDEX'
name|tar_name|load_ref|default_target_ref|platform|pull|dockerfile
INDEX
}

write_manifest_index() {
  local dest="$1"
  cat > "${dest}" <<'INDEX'
channel|file|apply_mode
standard|standard-install.yaml|server-side
experimental|experimental-install.yaml|server-side
INDEX
}

build_one() {
  local arch="$1"
  local platform build_dir payload_dir payload_tar run_name run_path asset
  platform="$(platform_for_arch "${arch}")"
  build_dir="${BUILD_ROOT}/${PACKAGE_NAME}-${VERSION}-${arch}"
  payload_dir="${build_dir}/payload"
  payload_tar="${build_dir}/payload.tar.gz"
  run_name="${PACKAGE_NAME}-${VERSION}-${arch}.run"
  run_path="${DIST_DIR}/${run_name}"

  info "building ${run_name} (${platform})"
  rm -rf "${build_dir}"
  mkdir -p "${payload_dir}/manifests" "${payload_dir}/images" "${payload_dir}/meta" "${DIST_DIR}"

  for asset in "${ASSETS[@]}"; do
    cp "${ASSET_CACHE_DIR}/${asset}" "${payload_dir}/manifests/${asset}"
  done

  cp "${ROOT_DIR}/images/image.json" "${payload_dir}/images/image.json"
  write_image_index "${payload_dir}/images/image-index.tsv"
  write_manifest_index "${payload_dir}/meta/manifest-index.tsv"

  cat > "${payload_dir}/meta/package.env" <<META
PACKAGE_NAME=${PACKAGE_NAME}
VERSION=${VERSION}
ARCH=${arch}
PLATFORM=${platform}
PACKAGE_TYPE=crd-only
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STANDARD_ASSET=${BASE_URL%/}/standard-install.yaml
EXPERIMENTAL_ASSET=${BASE_URL%/}/experimental-install.yaml
META

  (cd "${payload_dir}" && tar -czf "${payload_tar}" .)
  tar -tzf "${payload_tar}" >/dev/null
  cat "${ROOT_DIR}/install.sh" "${payload_tar}" > "${run_path}"
  chmod +x "${run_path}"
  (cd "${DIST_DIR}" && sha256sum "${run_name}" > "${run_name}.sha256")
  info "wrote ${run_path}"
  info "wrote ${run_path}.sha256"

  if [[ "${KEEP_BUILD}" != "1" ]]; then
    rm -rf "${build_dir}"
  fi
}

mkdir -p "${BUILD_ROOT}" "${DIST_DIR}"
ASSET_CACHE_DIR="$(prepare_assets)"

while read -r target_arch; do
  build_one "${target_arch}"
done < <(arch_list)

if [[ "${KEEP_BUILD}" != "1" ]]; then
  rm -rf "${ASSET_CACHE_DIR}"
fi

info "artifacts:"
ls -lh "${DIST_DIR}"/*.run "${DIST_DIR}"/*.sha256
