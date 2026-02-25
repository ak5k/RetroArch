#!/usr/bin/env bash
#
# Build universal (arm64 + x86_64) ffmpeg + x264 shared libraries from source.
# Output: deps/ffmpeg-universal/{lib,include}
#
# Requirements: Xcode CLI tools. Optional: nasm (for x86 asm optimizations).
#
#   ./ak5k_build_ffmpeg_universal.sh
#   FFMPEG_VERSION=7.1.1 ./ak5k_build_ffmpeg_universal.sh
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${REPO_ROOT}/deps/ffmpeg-universal"
BUILD_DIR="${REPO_ROOT}/.ffmpeg-build"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
X264_COMMIT="${X264_COMMIT:-stable}"
FFMPEG_LIBS=(libavformat libavcodec libswscale libswresample libavutil)
ARCHS=(arm64 x86_64)

SDKROOT="$(xcrun --show-sdk-path)"
NCPU="$(sysctl -n hw.ncpu)"
COMMON_FLAGS="-isysroot ${SDKROOT} -mmacosx-version-min=10.15"

SRC_DIR="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}"
X264_SRC="${BUILD_DIR}/x264"

# ── Download sources ─────────────────────────────────────────────────────────

download_sources() {
  mkdir -p "${BUILD_DIR}"
  if [[ ! -d "${X264_SRC}" ]]; then
    echo "Cloning x264 (${X264_COMMIT})..."
    git clone --depth 1 --branch "${X264_COMMIT}" \
      "https://code.videolan.org/videolan/x264.git" "${X264_SRC}"
  fi
  if [[ ! -d "${SRC_DIR}" ]]; then
    local tarball="${BUILD_DIR}/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    [[ -f "${tarball}" ]] || curl -fSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o "${tarball}"
    tar xf "${tarball}" -C "${BUILD_DIR}"
  fi
  [[ -d "${SRC_DIR}" ]] || { echo "error: ffmpeg source not found" >&2; exit 1; }
}

# ── Per-arch builds ──────────────────────────────────────────────────────────

needs_nasm() { [[ "$1" == "x86_64" ]] && ! command -v nasm &>/dev/null; }

build_x264() {
  local arch="$1"
  local prefix="${BUILD_DIR}/${arch}-x264"
  [[ -f "${prefix}/lib/libx264.dylib" ]] && { echo "  x264 ${arch}: cached"; return; }

  echo "=== x264 ${arch} ==="
  local obj="${BUILD_DIR}/${arch}-x264-obj"; mkdir -p "${obj}"; cd "${obj}"

  local asm=""; [[ "${arch}" == "arm64" ]] && asm="--disable-asm"
  needs_nasm "${arch}" && asm="--disable-asm"

  "${X264_SRC}/configure" --prefix="${prefix}" --host="${arch}-apple-darwin" \
    --extra-cflags="-arch ${arch} ${COMMON_FLAGS}" --extra-ldflags="-arch ${arch} ${COMMON_FLAGS}" \
    --enable-shared --disable-static --disable-cli --enable-pic ${asm}
  make -j"${NCPU}" && make install
  install_name_tool -id "@rpath/libx264.dylib" "${prefix}/lib/libx264.dylib" 2>/dev/null || true
}

build_ffmpeg() {
  local arch="$1"
  local prefix="${BUILD_DIR}/${arch}-install"
  local x264="${BUILD_DIR}/${arch}-x264"

  echo "=== ffmpeg ${FFMPEG_VERSION} ${arch} ==="
  local obj="${BUILD_DIR}/${arch}-obj"; mkdir -p "${obj}"; cd "${obj}"

  local asm=""; needs_nasm "${arch}" && asm="--disable-x86asm"

  "${SRC_DIR}/configure" --prefix="${prefix}" --arch="${arch}" \
    --cc="clang -arch ${arch}" --cxx="clang++ -arch ${arch}" \
    --extra-cflags="-arch ${arch} ${COMMON_FLAGS} -I${x264}/include" \
    --extra-ldflags="-arch ${arch} ${COMMON_FLAGS} -L${x264}/lib" \
    --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
    --enable-swresample --enable-avformat --enable-avcodec --enable-swscale \
    --enable-gpl --enable-version3 --enable-libx264 \
    --disable-network --disable-autodetect --install-name-dir='@rpath' ${asm}
  make -j"${NCPU}" 2>&1 && make install

  for lib in "${FFMPEG_LIBS[@]}"; do
    [[ -f "${prefix}/lib/${lib}.dylib" ]] || { echo "error: ${lib}.dylib missing" >&2; exit 1; }
  done
}

# ── Merge into universal ─────────────────────────────────────────────────────

create_universal() {
  echo "=== Creating universal libraries ==="
  rm -rf "${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}/lib" "${OUTPUT_DIR}/include"

  # Headers from arm64 build (identical across archs)
  cp -R "${BUILD_DIR}/arm64-x264/include/." "${OUTPUT_DIR}/include/"
  cp -R "${BUILD_DIR}/arm64-install/include/." "${OUTPUT_DIR}/include/"

  # Lipo each library
  local all_libs=("${FFMPEG_LIBS[@]}" libx264)
  for lib in "${all_libs[@]}"; do
    local arm64_dir="install" x86_dir="install"
    [[ "${lib}" == "libx264" ]] && arm64_dir="x264" && x86_dir="x264"

    local a="${BUILD_DIR}/arm64-${arm64_dir}/lib/${lib}.dylib"
    local x="${BUILD_DIR}/x86_64-${x86_dir}/lib/${lib}.dylib"
    local out="${OUTPUT_DIR}/lib/${lib}.dylib"

    lipo -create -output "${out}" "${a}" "${x}"
    install_name_tool -id "@rpath/${lib}.dylib" "${out}" 2>/dev/null || true

    # Versioned symlinks
    for v in "${BUILD_DIR}/arm64-${arm64_dir}/lib/${lib}".[0-9]*.dylib; do
      [[ -f "${v}" || -L "${v}" ]] && ln -sf "${lib}.dylib" "${OUTPUT_DIR}/lib/$(basename "${v}")"
    done
  done

  # Fix inter-library references to use @rpath
  for dylib in "${OUTPUT_DIR}"/lib/lib*.dylib; do
    [[ -L "${dylib}" ]] && continue
    for pattern in "${BUILD_DIR}"/*/lib/libx264.dylib; do
      if otool -L "${dylib}" 2>/dev/null | grep -q "${pattern}"; then
        install_name_tool -change "${pattern}" "@rpath/libx264.dylib" "${dylib}" 2>/dev/null || true
      fi
    done
  done

  # pkgconfig
  if [[ -d "${BUILD_DIR}/arm64-install/lib/pkgconfig" ]]; then
    mkdir -p "${OUTPUT_DIR}/lib/pkgconfig"
    for pc in "${BUILD_DIR}/arm64-install/lib/pkgconfig/"*.pc; do
      sed "s|${BUILD_DIR}/arm64-install|${OUTPUT_DIR}|g" "${pc}" > "${OUTPUT_DIR}/lib/pkgconfig/$(basename "${pc}")"
    done
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

echo "Building ffmpeg ${FFMPEG_VERSION} + x264 (universal) for macOS"
echo

download_sources

for arch in "${ARCHS[@]}"; do build_x264 "${arch}"; done
for arch in "${ARCHS[@]}"; do build_ffmpeg "${arch}"; done

create_universal

echo
echo "=== Done: ${OUTPUT_DIR} ==="
for lib in "${FFMPEG_LIBS[@]}" libx264; do
  f="${OUTPUT_DIR}/lib/${lib}.dylib"
  [[ -f "${f}" ]] && printf "  %-22s %s (%d KB)\n" "${lib}.dylib" "$(lipo -archs "${f}")" "$(( $(wc -c < "${f}" | tr -d ' ') / 1024 ))"
done
