#!/usr/bin/env bash

# set -u but not -e: unbound vars are bugs, but we want tests to continue after failures
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MAX_FRAMES="${MAX_FRAMES:-300}"
REQUIRE_PS1_BIOS_CHECK="${REQUIRE_PS1_BIOS_CHECK:-1}"

# Detect native architecture
NATIVE_ARCH="$(uname -m)"
# macOS default: x86_64 (Rosetta) because some buildbot cores lack arm64
# Other platforms: native arch
case "$(uname -s)" in
  Darwin) TEST_ARCH="${TEST_ARCH:-x86_64}" ;;
  *)      TEST_ARCH="${TEST_ARCH:-${NATIVE_ARCH}}" ;;
esac

AK5K_SETUP_LIB="${AK5K_SETUP_LIB:-$PWD/ak5k_test_env_setup.sh}"
if [[ ! -f "${AK5K_SETUP_LIB}" ]]; then
  echo "error: missing shared setup script: ${AK5K_SETUP_LIB}" >&2
  exit 1
fi
source "${AK5K_SETUP_LIB}"

# Platform-dependent core extension and binary name
AK5K_PLATFORM="$(ak5k_detect_platform)"
CORE_EXT="$(ak5k_core_ext)"

DEFAULT_CORE="${DEFAULT_CORE:-cores/lrps2_libretro.${CORE_EXT}}"
SWANSTATION_CORE="${SWANSTATION_CORE:-cores/swanstation_libretro.${CORE_EXT}}"
FALLBACK_LRPS2_CORE="cores/pcsx2_libretro.${CORE_EXT}"

PS1_TEST_ROM="${PS1_TEST_ROM:-system/ps1-tests/gpu/animated-triangle/animated-triangle.exe}"

WORKSPACE_SYSTEM_DIR="${WORKSPACE_SYSTEM_DIR:-$PWD/system}"
WORKSPACE_RECORDINGS_DIR="${WORKSPACE_RECORDINGS_DIR:-$PWD/recordings}"
mkdir -p "${WORKSPACE_SYSTEM_DIR}"
mkdir -p "${WORKSPACE_RECORDINGS_DIR}"

PS1_REQUIRED_BIOS=(
  "scph1001.bin"
)

# Check if a binary contains the requested architecture slice.
# On macOS uses lipo; on Linux/Windows uses file(1).
binary_has_arch() {
  local bin_path="$1"
  local wanted_arch="${2:-${TEST_ARCH}}"

  [[ -f "${bin_path}" ]] || return 1

  case "${AK5K_PLATFORM}" in
    macos)
      local archs
      archs="$(lipo -archs "${bin_path}" 2>/dev/null || true)"
      [[ -n "${archs}" ]] && [[ " ${archs} " == *" ${wanted_arch} "* ]]
      ;;
    linux)
      # file(1) reports e.g. "ELF 64-bit" or "ELF 32-bit"
      local file_out
      file_out="$(file -b "${bin_path}" 2>/dev/null || true)"
      case "${wanted_arch}" in
        x86_64|amd64)   [[ "${file_out}" == *"ELF 64-bit"*"x86-64"* ]] ;;
        aarch64|arm64)  [[ "${file_out}" == *"ELF 64-bit"*"ARM aarch64"* || "${file_out}" == *"ELF 64-bit"*"aarch64"* ]] ;;
        *)              [[ "${file_out}" == *"ELF"* ]] ;;  # best effort
      esac
      ;;
    windows)
      # On MSYS2, file(1) reports "PE32+" for 64-bit, "PE32" for 32-bit
      local file_out
      file_out="$(file -b "${bin_path}" 2>/dev/null || true)"
      case "${wanted_arch}" in
        x86_64|amd64)  [[ "${file_out}" == *"PE32+"* ]] ;;
        *)             [[ "${file_out}" == *"PE32"* ]] ;;
      esac
      ;;
    *)
      # Unknown platform — assume OK if file exists
      return 0
      ;;
  esac
}

find_retroarch_bin() {
  # 1. Explicit RA_BIN override
  if [[ -n "${RA_BIN:-}" && -x "${RA_BIN}" ]]; then
    if binary_has_arch "${RA_BIN}" "${TEST_ARCH}"; then
      echo "${RA_BIN}"
      return
    fi
  fi

  # 2. Platform-specific build output paths
  local candidates=()
  case "${AK5K_PLATFORM}" in
    macos)
      candidates+=(
        "./build/Release/RetroArch.app/Contents/MacOS/RetroArch"
        "./RetroArch.app/Contents/MacOS/RetroArch"
      )
      ;;
    windows)
      candidates+=(
        "./retroarch.exe"
        "./build/Release/retroarch.exe"
      )
      ;;
    linux)
      candidates+=(
        "./retroarch"
        "./build/retroarch"
      )
      ;;
  esac
  # Common fallback
  candidates+=("./retroarch")

  local c
  for c in "${candidates[@]}"; do
    if [[ -x "${c}" ]] && binary_has_arch "${c}" "${TEST_ARCH}"; then
      echo "${c}"
      return
    fi
  done

  # 3. macOS: Xcode DerivedData fallback
  if [[ "${AK5K_PLATFORM}" == "macos" ]]; then
    while IFS= read -r derived; do
      if [[ -n "${derived}" && -x "${derived}" ]] && binary_has_arch "${derived}" "${TEST_ARCH}"; then
        echo "${derived}"
        return
      fi
    done < <(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/RetroArch-*/Build/Products/Release/RetroArch.app/Contents/MacOS/RetroArch 2>/dev/null)
  fi

  return 1
}

RETROARCH_BIN="$(find_retroarch_bin)"
if [[ -z "${RETROARCH_BIN}" ]]; then
  echo "info: no ${TEST_ARCH} RetroArch binary found; attempting auto-build..."
  case "${AK5K_PLATFORM}" in
    macos)
      if [[ -x "${REPO_ROOT}/build-macos.sh" ]]; then
        "${REPO_ROOT}/build-macos.sh"
      else
        echo "error: build-macos.sh not found" >&2; exit 1
      fi
      ;;
    linux)
      if [[ -f "${REPO_ROOT}/Makefile" ]]; then
        make -C "${REPO_ROOT}" -j"$(nproc 2>/dev/null || echo 4)"
      else
        echo "error: no build system found for Linux" >&2; exit 1
      fi
      ;;
    *)
      echo "error: auto-build not supported on ${AK5K_PLATFORM}. Set RA_BIN=/path/to/retroarch." >&2
      exit 1
      ;;
  esac

  RETROARCH_BIN="$(find_retroarch_bin)"

  if [[ -z "${RETROARCH_BIN}" ]]; then
    echo "error: RetroArch binary with ${TEST_ARCH} slice not found. Set RA_BIN=/path/to/RetroArch." >&2
    exit 1
  fi
fi

if ! binary_has_arch "${RETROARCH_BIN}"; then
  echo "error: RetroArch binary does not contain ${TEST_ARCH} slice: ${RETROARCH_BIN}" >&2
  exit 1
fi

run_retroarch() {
  local env_prefix=(env "LIBRETRO_SYSTEM_DIRECTORY=${WORKSPACE_SYSTEM_DIR}")

  if [[ "${AK5K_PLATFORM}" == "macos" && "${TEST_ARCH}" != "${NATIVE_ARCH}" ]]; then
    # Rosetta translation on macOS
    "${env_prefix[@]}" arch "-${TEST_ARCH}" "${RETROARCH_BIN}" "$@"
  else
    "${env_prefix[@]}" "${RETROARCH_BIN}" "$@"
  fi
}

ak5k_prepare_test_dependencies \
  "${SWANSTATION_CORE}" \
  "${DEFAULT_CORE}" \
  "${FALLBACK_LRPS2_CORE}" \
  "${WORKSPACE_SYSTEM_DIR}"

core_supports_test_arch() {
  [[ -f "$1" ]] && binary_has_arch "$1"
}

has_bios_file() {
  local bios_name="$1"

  [[ -f "${WORKSPACE_SYSTEM_DIR}/${bios_name}" ]] && return 0

  local upper_name
  upper_name="$(printf '%s' "${bios_name}" | tr '[:lower:]' '[:upper:]')"
  [[ -f "${WORKSPACE_SYSTEM_DIR}/${upper_name}" ]]
}

preflight_ps1_bios() {
  if [[ "${REQUIRE_PS1_BIOS_CHECK}" != "1" ]]; then
    return 0
  fi

  local missing=()
  local bios

  for bios in "${PS1_REQUIRED_BIOS[@]}"; do
    if ! has_bios_file "${bios}"; then
      missing+=("${bios}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "error: required PS1 BIOS file(s) missing from ${WORKSPACE_SYSTEM_DIR}:" >&2
    for bios in "${missing[@]}"; do
      echo "  - ${bios}" >&2
    done
    echo "error: add BIOS files to workspace/system or set REQUIRE_PS1_BIOS_CHECK=0 to bypass." >&2
    return 1
  fi

  return 0
}

if ! core_supports_test_arch "${DEFAULT_CORE}" && core_supports_test_arch "${FALLBACK_LRPS2_CORE}"; then
  DEFAULT_CORE="${FALLBACK_LRPS2_CORE}"
fi

if ! core_supports_test_arch "${DEFAULT_CORE}"; then
  echo "warning: default core not found: ${DEFAULT_CORE}" >&2
fi
if ! core_supports_test_arch "${SWANSTATION_CORE}"; then
  echo "warning: SwanStation core not found: ${SWANSTATION_CORE}" >&2
fi
if ! preflight_ps1_bios; then
  exit 1
fi
if [[ ! -f "${PS1_TEST_ROM}" ]]; then
  echo "warning: PS1 test ROM not found: ${PS1_TEST_ROM}" >&2
fi

mkdir -p recordings logs

echo
if [[ "${AK5K_PLATFORM}" == "macos" && "${TEST_ARCH}" != "${NATIVE_ARCH}" ]]; then
  echo "info: running tests under Rosetta (${TEST_ARCH})"
else
  echo "info: running tests natively (${TEST_ARCH}) on ${AK5K_PLATFORM}"
fi
echo "info: system directory override: ${WORKSPACE_SYSTEM_DIR}"
echo

run_test() {
  local index="$1"
  local name="$2"
  local cfg="$3"
  local rec_file="$4"
  local core="$5"
  local content="$6"
  local renderer="$7"

  echo "=== Test ${index}: ${name} ==="

  if [[ ! -f "${cfg}" ]]; then
    echo "  [SKIP] Config file '${cfg}' not found."
    echo
    return
  fi

  if ! core_supports_test_arch "${core}"; then
    echo "  [SKIP] Core missing or incompatible for test arch (${TEST_ARCH}): ${core}"
    echo
    return
  fi

  rm -f logs/retroarch.log
  rm -f retroarch.cfg
  rm -rf config
  rm -rf system/pcsx2/cache

  if [[ -n "${renderer}" ]]; then
    mkdir -p config/LRPS2
    printf 'pcsx2_renderer = "%s"\n' "${renderer}" > config/LRPS2/LRPS2.opt
  fi

  if [[ "${core}" == *"swanstation"* ]]; then
    mkdir -p config/SwanStation
    printf 'swanstation_GPU_Renderer = "Software"\n' > config/SwanStation/SwanStation.opt
  fi

  local rec_file_abs="${rec_file}"
  if [[ "${rec_file_abs}" != /* ]]; then
    rec_file_abs="$PWD/${rec_file_abs}"
  fi
  mkdir -p "$(dirname "${rec_file_abs}")"

  local test_cfg
  test_cfg="$(mktemp "${TMPDIR:-/tmp}/ra-test-cfg.XXXXXX")"
  cp -f "${cfg}" "${test_cfg}"
  printf 'recording_output_directory = "%s"\n' "${WORKSPACE_RECORDINGS_DIR}" >> "${test_cfg}"

  touch .test_start_marker

  local args=()
  args+=("-L" "${core}")
  args+=("--appendconfig" "${test_cfg}")
  args+=("-r" "${rec_file_abs}")
  args+=("--max-frames=${MAX_FRAMES}")
  args+=("-v")
  if [[ -n "${content}" ]]; then
    args+=("${content}")
  fi

  run_retroarch "${args[@]}" &
  local pid=$!

  wait "${pid}" 2>/dev/null || true

  if [[ -f logs/retroarch.log ]]; then
    local log_size
    log_size="$(wc -c < logs/retroarch.log | tr -d ' ')"
    echo "  Log: logs/retroarch.log (${log_size} bytes)"

    local errors
    errors="$(grep -Ei 'VK_ERROR|\[ERROR\]|BLACK' logs/retroarch.log | grep -Evi 'IsoFS|record driver|camera driver|disc index' || true)"
    local rec_lines
    rec_lines="$(grep -Ei 'Recording|readback|async|gpu_record' logs/retroarch.log || true)"

    if [[ -n "${rec_lines}" ]]; then
      echo "  Recording-related log lines:"
      while IFS= read -r line; do
        [[ -n "${line}" ]] && echo "    ${line}"
      done <<< "${rec_lines}"
    fi

    if [[ -n "${errors}" ]]; then
      echo "  [FAIL] Errors found:"
      while IFS= read -r line; do
        [[ -n "${line}" ]] && echo "    ${line}"
      done <<< "${errors}"
    else
      echo "  [OK] No errors in log."
    fi
  else
    echo "  [WARN] No log file found."
  fi

  local best_rec=""
  local best_size=-1
  while IFS= read -r -d '' rec; do
    local rec_size
    rec_size="$(wc -c < "${rec}" 2>/dev/null || echo 0)"
    if (( rec_size > best_size )); then
      best_size="${rec_size}"
      best_rec="${rec}"
    fi
  done < <(find "${WORKSPACE_RECORDINGS_DIR}" -maxdepth 1 -type f -name '*.mkv' -newer .test_start_marker -print0 2>/dev/null)

  if [[ -n "${best_rec}" && -f "${best_rec}" ]]; then
    local size_kb
    size_kb="$(awk "BEGIN { printf \"%.1f\", ${best_size} / 1024 }")"
    echo "  Recording: $(basename "${best_rec}") (${size_kb} KB)"
    if (( best_size < 1024 )); then
      echo "  [FAIL] Recording too small — likely not finalized."
    else
      echo "  [PASS]"
    fi
  else
    echo "  [FAIL] No recording found."
  fi

  rm -f "${test_cfg}"
  rm -f .test_start_marker
  echo
}

run_test "1" "CLI vulkan" "vulkan.cfg" "recordings/vulkan.mkv" "${DEFAULT_CORE}" "" "Auto"
run_test "2" "CLI glcore" "glcore.cfg" "recordings/glcore.mkv" "${DEFAULT_CORE}" "" "Auto"
run_test "3" "CLI gl" "gl2.cfg" "recordings/gl.mkv" "${SWANSTATION_CORE}" "${PS1_TEST_ROM}" ""

rm -f retroarch.cfg
rm -rf config

echo "=== All CLI tests complete ==="
