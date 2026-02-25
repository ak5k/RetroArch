#!/usr/bin/env bash
#
# Build RetroArch on Linux with a sanitized system environment.
#
# Environment variables:
#   FORCE_SYSTEM_FFMPEG=1      Prefer system pkg-config/libs over Linuxbrew/Homebrew paths
#   CLEAN_BUILD_ENV=1          Run distclean/clean and reconfigure
#   INSTALL_LINUX_BUILD_DEPS=1 Install apt build deps (if apt-get available)
#   BUILD_JOBS=<n>             Override make -j jobs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCE_SYSTEM_FFMPEG="${FORCE_SYSTEM_FFMPEG:-1}"
CLEAN_BUILD_ENV="${CLEAN_BUILD_ENV:-1}"
INSTALL_LINUX_BUILD_DEPS="${INSTALL_LINUX_BUILD_DEPS:-1}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"

[[ -x "${REPO_ROOT}/configure" ]] || { echo "error: configure script not found" >&2; exit 1; }

pushd "${REPO_ROOT}" > /dev/null

configure_args=()
linux_build_env=()
clean_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
pkg_dirs="/usr/lib/pkgconfig:/usr/share/pkgconfig"
multiarch="$(gcc -print-multiarch 2>/dev/null || true)"

if [[ -n "${multiarch}" ]]; then
  pkg_dirs="/usr/lib/${multiarch}/pkgconfig:${pkg_dirs}"
fi

if [[ "${INSTALL_LINUX_BUILD_DEPS}" == "1" ]] && command -v apt-get >/dev/null 2>&1; then
  apt_deps=(
    pkg-config
    libavcodec-dev
    libavformat-dev
    libavdevice-dev
    libswscale-dev
    libswresample-dev
    libavutil-dev
    libx11-dev
    libx11-xcb-dev
    libxcb1-dev
    libxext-dev
    libxi-dev
    libxinerama-dev
    libxrandr-dev
    libxss-dev
    libxxf86vm-dev
    libxkbcommon-dev
  )

  sudo_cmd=()
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_cmd=(sudo)
    else
      echo "warning: sudo not found; skipping automatic Linux dependency install." >&2
    fi
  fi

  if [[ ${#sudo_cmd[@]} -gt 0 || "$(id -u)" -eq 0 ]]; then
    echo "info: installing Linux build dependencies (ffmpeg + x11 + pkg-config) ..."
    "${sudo_cmd[@]}" apt-get update
    "${sudo_cmd[@]}" apt-get install -y "${apt_deps[@]}"
  fi
fi

if [[ "${FORCE_SYSTEM_FFMPEG}" == "1" || "${CLEAN_BUILD_ENV}" == "1" ]]; then
  linux_build_env+=("PATH=${clean_path}")
  linux_build_env+=("PKG_CONFIG=/usr/bin/pkg-config")
  linux_build_env+=("PKG_CONFIG_LIBDIR=${pkg_dirs}")
  linux_build_env+=("PKG_CONFIG_PATH=")
  linux_build_env+=("CPATH=")
  linux_build_env+=("C_INCLUDE_PATH=")
  linux_build_env+=("CPLUS_INCLUDE_PATH=")
  linux_build_env+=("LIBRARY_PATH=")
  linux_build_env+=("LD_LIBRARY_PATH=")
  linux_build_env+=("CPPFLAGS=")
  linux_build_env+=("CFLAGS=")
  linux_build_env+=("CXXFLAGS=")
  linux_build_env+=("LDFLAGS=")

  unset HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY
  while IFS= read -r env_var; do
    unset "${env_var}"
  done < <(compgen -A variable | grep -E '^(SNAP|HOMEBREW|LINUXBREW)')
fi

if [[ "${CLEAN_BUILD_ENV}" == "1" ]]; then
  echo "info: preparing clean Linux build environment ..."
  make distclean >/dev/null 2>&1 || make clean >/dev/null 2>&1 || true
  rm -f config.mk
fi

if [[ "${FORCE_SYSTEM_FFMPEG}" == "1" && -f config.mk ]] && grep -Eqi 'linuxbrew|homebrew' config.mk; then
  echo "info: existing config.mk uses Linuxbrew/Homebrew paths; reconfiguring for system libraries ..."
  rm -f config.mk
fi

if env "${linux_build_env[@]}" pkg-config --exists x11 xcb xext xi xinerama xrandr xscrnsaver 2>/dev/null; then
  echo "info: X11 deps found — enabling X11 build ..."
  configure_args+=("--enable-x11")
elif env "${linux_build_env[@]}" pkg-config --exists wayland-client 2>/dev/null; then
  echo "info: X11 deps not found — falling back to Wayland build ..."
  configure_args+=("--enable-wayland" "--disable-x11")
fi

if [[ "${CLEAN_BUILD_ENV}" == "1" || ! -f config.mk ]]; then
  if [[ "${FORCE_SYSTEM_FFMPEG}" == "1" ]]; then
    echo "info: running ./configure with system pkg-config paths ..."
  else
    echo "info: running ./configure ..."
  fi
  env "${linux_build_env[@]}" ./configure "${configure_args[@]}"
fi

env "${linux_build_env[@]}" make -j"${BUILD_JOBS}"

popd > /dev/null
