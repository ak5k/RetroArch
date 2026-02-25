#!/usr/bin/env bash

# --- Platform detection (shared by all functions) ---

ak5k_detect_platform() {
  local uname_s
  uname_s="$(uname -s)"
  case "${uname_s}" in
    Darwin)  echo "macos"   ;;
    Linux)   echo "linux"   ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)       echo "unknown" ;;
  esac
}

ak5k_core_ext() {
  case "$(ak5k_detect_platform)" in
    macos)   echo "dylib" ;;
    linux)   echo "so"    ;;
    windows) echo "dll"   ;;
    *)       echo "so"    ;;
  esac
}

# Buildbot base URL for the current platform + architecture.
# macOS has per-arch subdirectories; Linux/Windows do not.
ak5k_buildbot_core_url() {
  local core_basename="$1"  # e.g. "swanstation_libretro"
  local ext
  ext="$(ak5k_core_ext)"
  local arch
  arch="$(uname -m)"
  local platform
  platform="$(ak5k_detect_platform)"

  case "${platform}" in
    macos)   echo "https://buildbot.libretro.com/nightly/apple/osx/${arch}/latest/${core_basename}.${ext}.zip" ;;
    linux)   echo "https://buildbot.libretro.com/nightly/linux/${arch}/latest/${core_basename}.${ext}.zip" ;;
    windows) echo "https://buildbot.libretro.com/nightly/windows/${arch}/latest/${core_basename}.${ext}.zip" ;;
    *)       return 1 ;;
  esac
}

# --- Core download ---

ak5k_download_core() {
  local core_basename="$1"  # e.g. "swanstation_libretro"
  local out_path="$2"
  local platform
  platform="$(ak5k_detect_platform)"
  local ext
  ext="$(ak5k_core_ext)"

  if [[ "${platform}" == "macos" ]]; then
    ak5k_download_core_macos "${core_basename}" "${out_path}"
  else
    ak5k_download_core_single "${core_basename}" "${out_path}"
  fi
}

# macOS: try both arm64 + x86_64, lipo into universal binary
ak5k_download_core_macos() {
  local core_basename="$1"
  local out_path="$2"
  local ext
  ext="$(ak5k_core_ext)"
  local lib_name="${core_basename}.${ext}"
  local base_url="https://buildbot.libretro.com/nightly/apple/osx"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local arch_found=0

  for arch in arm64 x86_64; do
    local zip_path="${tmp_dir}/${lib_name}.${arch}.zip"
    local url="${base_url}/${arch}/latest/${lib_name}.zip"
    if curl -fsSL "${url}" -o "${zip_path}"; then
      arch_found=$((arch_found + 1))
      mkdir -p "${tmp_dir}/${arch}"
      if unzip -oq "${zip_path}" -d "${tmp_dir}/${arch}"; then
        :
      else
        echo "warning: failed to unzip ${lib_name} (${arch})" >&2
      fi
    fi
  done

  if [[ "${arch_found}" -eq 0 ]]; then
    rm -rf "${tmp_dir}"
    return 1
  fi

  local arm64_bin="${tmp_dir}/arm64/${lib_name}"
  local x64_bin="${tmp_dir}/x86_64/${lib_name}"
  mkdir -p "$(dirname "${out_path}")"

  if [[ -f "${arm64_bin}" && -f "${x64_bin}" ]]; then
    if ! lipo -create -output "${out_path}" "${arm64_bin}" "${x64_bin}"; then
      echo "warning: failed to create universal ${lib_name}, using arm64 build" >&2
      cp -f "${arm64_bin}" "${out_path}"
    fi
  elif [[ -f "${arm64_bin}" ]]; then
    cp -f "${arm64_bin}" "${out_path}"
  elif [[ -f "${x64_bin}" ]]; then
    cp -f "${x64_bin}" "${out_path}"
  else
    rm -rf "${tmp_dir}"
    return 1
  fi

  rm -rf "${tmp_dir}"
  return 0
}

# Linux / Windows: single architecture download
ak5k_download_core_single() {
  local core_basename="$1"
  local out_path="$2"
  local ext
  ext="$(ak5k_core_ext)"
  local lib_name="${core_basename}.${ext}"
  local url
  url="$(ak5k_buildbot_core_url "${core_basename}")" || return 1

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local zip_path="${tmp_dir}/${lib_name}.zip"

  if curl -fsSL "${url}" -o "${zip_path}"; then
    if unzip -oq "${zip_path}" -d "${tmp_dir}"; then
      if [[ -f "${tmp_dir}/${lib_name}" ]]; then
        mkdir -p "$(dirname "${out_path}")"
        cp -f "${tmp_dir}/${lib_name}" "${out_path}"
        rm -rf "${tmp_dir}"
        return 0
      fi
    fi
  fi

  rm -rf "${tmp_dir}"
  return 1
}

ak5k_install_lrps2_system_files() {
  local target_system_dir="$1"
  local tmp_zip
  tmp_zip="$(mktemp)"
  local url="https://buildbot.libretro.com/assets/system/LRPS2.zip"

  if curl -fsSL "${url}" -o "${tmp_zip}"; then
    mkdir -p "${target_system_dir}"
    if unzip -oq "${tmp_zip}" -d "${target_system_dir}"; then
      echo "info: installed LRPS2 system files to ${target_system_dir}"
    else
      echo "warning: failed to extract LRPS2 system files" >&2
    fi
  else
    echo "warning: failed to download LRPS2 system files from ${url}" >&2
  fi

  rm -f "${tmp_zip}"
}

ak5k_install_ps1_bios() {
  local target_system_dir="$1"
  local dest="${target_system_dir}/scph1001.bin"

  [[ -f "${dest}" ]] && { echo "info: PS1 BIOS already present"; return 0; }

  local url="https://ps1emulator.com/SCPH1001.BIN"
  mkdir -p "${target_system_dir}"
  if curl -fsSL "${url}" -o "${dest}"; then
    echo "info: downloaded PS1 BIOS to ${dest}"
  else
    echo "warning: failed to download PS1 BIOS from ${url}" >&2
    return 1
  fi
}

ak5k_install_ps2_bios() {
  local target_system_dir="$1"
  local bios_dir="${target_system_dir}/pcsx2/bios"
  local bios_name="SCPH-70012_BIOS_V12_USA_200"

  [[ -f "${bios_dir}/${bios_name}.BIN" ]] && { echo "info: PS2 BIOS (70012) already present"; return 0; }

  local tmp_zip
  tmp_zip="$(mktemp)"
  local url="https://pcsx2bios.com/wp-content/uploads/download/ps2/ps2-bios-usa.zip"

  if curl -fsSL "${url}" -o "${tmp_zip}"; then
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if unzip -oq "${tmp_zip}" -d "${tmp_dir}"; then
      mkdir -p "${bios_dir}"
      # Find the 70012 BIOS files inside the nested zip structure
      while IFS= read -r -d '' f; do
        cp -f "${f}" "${bios_dir}/"
      done < <(find "${tmp_dir}" -name "${bios_name}.*" -print0)

      if [[ -f "${bios_dir}/${bios_name}.BIN" ]]; then
        echo "info: installed PS2 BIOS (70012) to ${bios_dir}"
      else
        echo "warning: extracted PS2 BIOS zip but ${bios_name}.BIN not found inside" >&2
      fi
    else
      echo "warning: failed to extract PS2 BIOS zip" >&2
    fi
    rm -rf "${tmp_dir}"
  else
    echo "warning: failed to download PS2 BIOS from ${url}" >&2
  fi

  rm -f "${tmp_zip}"
}

ak5k_install_ps1_test_rom() {
  local target_system_dir="$1"
  local dest="${target_system_dir}/ps1-tests/gpu/animated-triangle/animated-triangle.exe"

  [[ -f "${dest}" ]] && { echo "info: ps1-tests ROM already present"; return 0; }

  local tmp_zip
  tmp_zip="$(mktemp)"
  local url="https://github.com/JaCzekanski/ps1-tests/releases/download/build-158/tests.zip"

  if curl -fsSL "${url}" -o "${tmp_zip}"; then
    mkdir -p "${target_system_dir}/ps1-tests"
    if unzip -oq "${tmp_zip}" -d "${target_system_dir}/ps1-tests"; then
      echo "info: installed ps1-tests to ${target_system_dir}/ps1-tests"
    else
      echo "warning: failed to extract ps1-tests zip" >&2
    fi
  else
    echo "warning: failed to download ps1-tests from ${url}" >&2
  fi

  rm -f "${tmp_zip}"
}

ak5k_prepare_test_dependencies() {
  local swanstation_core_path="$1"
  local lrps2_core_path="$2"
  local fallback_lrps2_core_path="$3"
  local target_system_dir="$4"

  echo "=== Preparing test dependencies (cores + system files + ROMs) ==="

  if ak5k_download_core "swanstation_libretro" "${swanstation_core_path}"; then
    echo "info: downloaded ${swanstation_core_path}"
  else
    echo "warning: failed to download swanstation core" >&2
  fi

  if ak5k_download_core "lrps2_libretro" "${lrps2_core_path}"; then
    echo "info: downloaded ${lrps2_core_path}"
  elif ak5k_download_core "pcsx2_libretro" "${fallback_lrps2_core_path}"; then
    echo "info: downloaded ${fallback_lrps2_core_path} (LRPS2 fallback)"
  else
    echo "warning: could not download lrps2/pcsx2 core from buildbot" >&2
  fi

  ak5k_install_lrps2_system_files "${target_system_dir}"
  ak5k_install_ps1_bios "${target_system_dir}"
  ak5k_install_ps2_bios "${target_system_dir}"
  ak5k_install_ps1_test_rom "${target_system_dir}"
  echo
}
