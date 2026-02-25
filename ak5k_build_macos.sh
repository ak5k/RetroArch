#!/usr/bin/env bash
#
# Build RetroArch for macOS with ffmpeg/x264 support.
#
#   BUILD_ARCH=universal ./ak5k_build_macos.sh     (default)
#   BUILD_ARCH=arm64 ./ak5k_build_macos.sh
#   ENABLE_FFMPEG=0 ./ak5k_build_macos.sh          (skip ffmpeg)
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${REPO_ROOT}/pkg/apple/RetroArch.xcworkspace"
SCHEME="${SCHEME:-RetroArch}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_ARCH="${BUILD_ARCH:-universal}"
ENABLE_FFMPEG="${ENABLE_FFMPEG:-1}"

# ── Architecture ─────────────────────────────────────────────────────────────

case "${BUILD_ARCH}" in
  x86_64)   ARCHS="x86_64";        ONLY_ACTIVE=YES ;;
  arm64)    ARCHS="arm64";         ONLY_ACTIVE=YES ;;
  universal) ARCHS="x86_64 arm64"; ONLY_ACTIVE=NO  ;;
  *) echo "error: BUILD_ARCH must be x86_64|arm64|universal" >&2; exit 1 ;;
esac

# ── FFmpeg ───────────────────────────────────────────────────────────────────

FFMPEG_XCODE_ARGS=()
if [[ "${ENABLE_FFMPEG}" == "1" ]]; then
  FFMPEG_PREFIX="${FFMPEG_PREFIX:-}"

  # Locate or build ffmpeg
  if [[ -z "${FFMPEG_PREFIX}" ]]; then
    if [[ -d "${REPO_ROOT}/deps/ffmpeg-universal/lib" ]]; then
      FFMPEG_PREFIX="${REPO_ROOT}/deps/ffmpeg-universal"
    elif [[ -x "${REPO_ROOT}/ak5k_build_ffmpeg_universal.sh" ]]; then
      echo "FFmpeg not found — building from source..."
      "${REPO_ROOT}/ak5k_build_ffmpeg_universal.sh"
      FFMPEG_PREFIX="${REPO_ROOT}/deps/ffmpeg-universal"
    else
      FFMPEG_PREFIX="$(brew --prefix ffmpeg 2>/dev/null || true)"
    fi
  fi

  if [[ -n "${FFMPEG_PREFIX}" && -d "${FFMPEG_PREFIX}/include" ]]; then
    echo "FFmpeg: ${FFMPEG_PREFIX} ($(lipo -archs "${FFMPEG_PREFIX}/lib/libavcodec.dylib" 2>/dev/null || echo ?))"
    FFMPEG_XCODE_ARGS=(
      "OTHER_CFLAGS=\$(inherited) -DHAVE_FFMPEG -DHAVE_SWRESAMPLE -I${FFMPEG_PREFIX}/include"
      "OTHER_LDFLAGS=-L${FFMPEG_PREFIX}/lib -lavformat -lavcodec -lswscale -lswresample -lavutil -lx264"
      "HEADER_SEARCH_PATHS=\$(inherited) ${FFMPEG_PREFIX}/include"
    )
  else
    echo "warning: ffmpeg not found — building without it" >&2
    ENABLE_FFMPEG=0
  fi
fi

# ── Build ────────────────────────────────────────────────────────────────────

[[ -d "${WORKSPACE}" ]] || { echo "error: workspace not found: ${WORKSPACE}" >&2; exit 1; }

BUILD_DIR="${REPO_ROOT}/build"

echo "Building ${SCHEME} (${CONFIGURATION}) arch=${BUILD_ARCH} ffmpeg=${ENABLE_FFMPEG}"

PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH}" \
xcodebuild \
  -workspace "${WORKSPACE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "platform=macOS" \
  ARCHS="${ARCHS}" \
  ONLY_ACTIVE_ARCH="${ONLY_ACTIVE}" \
  "${FFMPEG_XCODE_ARGS[@]}" \
  SYMROOT="${BUILD_DIR}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  build

# ── Post-build: locate app and embed dylibs ─────────────────────────────────

APP_PATH="${BUILD_DIR}/${CONFIGURATION}/RetroArch.app"

if [[ -d "${APP_PATH}" ]]; then
  echo "App: ${APP_PATH}"

  # Embed ffmpeg + x264 dylibs
  if [[ "${ENABLE_FFMPEG}" == "1" && -n "${FFMPEG_PREFIX:-}" ]]; then
    FW="${APP_PATH}/Contents/Frameworks"
    echo "Embedding ffmpeg dylibs..."
    for lib in libavformat libavcodec libswscale libswresample libavutil libx264; do
      [[ -f "${FFMPEG_PREFIX}/lib/${lib}.dylib" ]] && cp -f "${FFMPEG_PREFIX}/lib/${lib}.dylib" "${FW}/"
    done
    # Versioned symlinks (ffmpeg inter-library references use them)
    for link in "${FFMPEG_PREFIX}"/lib/lib*.*.dylib; do
      local_target="$(readlink "${link}" 2>/dev/null || true)"
      [[ -n "${local_target}" ]] && ln -sf "${local_target}" "${FW}/$(basename "${link}")"
    done
  fi

  BIN="${APP_PATH}/Contents/MacOS/RetroArch"
  [[ -x "${BIN}" ]] && echo "Slices: $(lipo -archs "${BIN}" 2>/dev/null || echo unknown)"
  echo "Launch: open \"${APP_PATH}\""
fi
