#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
# Script Purpose and Overview:
# This script installs essential development, performance, and debugging tools on Raspberry Pi OS Lite (64-bit, kernel 6.6, Debian 12 Bookworm) 
# running on Raspberry Pi 5 hardware. It installs GoLang, performance monitoring tools (both general and advanced), profiling/debugging utilities, 
# and other useful system utilities to optimize the Raspberry Pi for development and performance analysis. The script also enables NTP time 
# synchronization and performs a system upgrade before rebooting to apply all changes.
#
# Key Features and Installations:
# 1. GoLang Installation:
#    - Downloads and installs the latest stable version of GoLang for ARM64 directly from the official Go website. 
#    - If the download or installation fails, it falls back to installing GoLang from the `apt` repositories.
#    - Sets up GoLang environment variables globally for all users on the system.
#
# 2. General Linux Performance Tools:
#    - Installs system performance tools like `linux-perf`, `htop`, `sysstat`, and others to monitor CPU usage, memory statistics, and system health.
#    - Configures `sysstat` to enable data collection and restarts the necessary services.
#
# 3. Advanced Performance Tools:
#    - Installs advanced performance tools such as `bpfcc-tools`, `bpftrace`, `strace`, `ltrace`, and `trace-cmd` for in-depth performance monitoring 
#      and system tracing.
#
# 4. Profiling and Debugging Tools:
#    - Installs essential profiling and debugging utilities such as `cppcheck`, `gprof`, `valgrind`, and `gdb` for C/C++ development.
#    - Clones the `FlameGraph` repository from GitHub to enable the generation of flame graphs for visual performance analysis.
#
# 5. Useful System Utilities:
#    - Installs additional utilities such as `iotop`, `iftop`, and `ncdu` for monitoring disk I/O, network usage, and disk space utilization.
#
# 6. Time Synchronization:
#    - Ensures that NTP time synchronization is enabled using `timedatectl` to maintain accurate system time, which is important for performance 
#      monitoring and logging in a headless server setup.
#
# 7. System Upgrade and Reboot:
#    - Performs a final `apt-get update` and `apt-get upgrade` to ensure that all installed packages are up to date.
#    - Reboots the system to apply all changes and optimizations.
#
# Function to handle errors and clean up
error_exit() {
    # echo "Error on line $1"
    # rm -f /tmp/golang.tar.gz  # Clean up temporary files in case of failure
    echo "Error at line ${2:-$LINENO}: ${BASH_COMMAND:-unknown} (${1})" >&2
    exit 1
}

# Function to verify if packages were installed
verify_package_installation() {
    for package in "$@"; do
        if dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
            echo "$package installed successfully."
        else
            echo "$package installation failed."
            error_exit $LINENO
        fi
    done
}

# Trap errors and clean up on exit
trap 'error_exit $LINENO' ERR

# Update package list
echo "Updating package list..."
apt-get update || error_exit $LINENO
echo "Package list updated successfully."

# Step 1: Install GCC and build-essential
echo "Installing GCC and build-essential (build-essential)..."
apt-get install -y build-essential || error_exit $LINENO
verify_package_installation build-essential

# Step 2: Install vcgencmd (raspi-utils)
echo "Installing vcgencmd utility (raspi-utils)..."
apt-get install -y raspi-utils || error_exit $LINENO
verify_package_installation raspi-utils
which vcgencmd && echo "vcgencmd installed successfully" || { echo "vcgencmd installation failed"; error_exit $LINENO; }

# Step 3: Read the latest stable ARM64 archive and checksum from official metadata
echo "Checking official Go release metadata for the latest stable ARM64 version..."
latest_golang_record="$(wget -qO- 'https://go.dev/dl/?mode=json' | python3 -c '
import json, re, sys
try:
    for release in json.load(sys.stdin):
        if release.get("stable") is not True:
            continue
        for archive in release.get("files", []):
            if (archive.get("os"), archive.get("arch"), archive.get("kind")) != ("linux", "arm64", "archive"):
                continue
            filename = archive.get("filename", "")
            checksum = archive.get("sha256", "")
            if not re.fullmatch(r"go[0-9]+\.[0-9]+(?:\.[0-9]+)?\.linux-arm64\.tar\.gz", filename) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
                raise ValueError("invalid archive filename or SHA-256")
            print(filename, checksum)
            sys.exit(0)
    raise ValueError("no stable Linux ARM64 archive found")
except (ValueError, TypeError, AttributeError) as error:
    print("Go release metadata rejected: " + str(error), file=sys.stderr)
    sys.exit(1)
')" || latest_golang_record=""

## Download and install GoLang from the determined URL
#wget "$latest_golang_url" -O /tmp/golang.tar.gz || error_exit $LINENO
#wget "${latest_golang_url}.sha256" -O /tmp/golang.tar.gz.sha256 || error_exit $LINENO
#expected="$(tr -d ' \r\n' </tmp/golang.tar.gz.sha256)"
#actual="$(sha256sum /tmp/golang.tar.gz | awk '{print $1}')"
#[ "$expected" = "$actual" ] || { echo "Go tarball checksum mismatch"; error_exit $LINENO; }
## tar -C /usr/local -xzf /tmp/golang.tar.gz || error_exit $LINENO
#if command -v pigz >/dev/null 2>&1; then
#  tar --no-same-owner --no-same-permissions --delay-directory-restore -I pigz -xf /tmp/golang.tar.gz -C /usr/local || error_exit $LINENO   # use pigz to unpack
#else
#  tar --no-same-owner --no-same-permissions --delay-directory-restore -xzf /tmp/golang.tar.gz -C /usr/local || error_exit $LINENO
#fi
#rm -f /tmp/golang.tar.gz  # Clean up
#echo "GoLang downloaded and installed."

if [ -z "$latest_golang_record" ]; then
  echo "Go release discovery failed; will try apt later." >&2
else
  read -r latest_golang_filename expected_golang_sha256 <<< "$latest_golang_record"
  latest_golang_url="https://go.dev/dl/$latest_golang_filename"
  echo "Downloading GoLang from $latest_golang_url..."
  if ! wget "$latest_golang_url" -O /tmp/golang.tar.gz || \
     [ "$expected_golang_sha256" != "$(sha256sum /tmp/golang.tar.gz | awk '{print $1}')" ]; then
    echo "Go tarball fetch/verify failed; will try apt later." >&2
  else
    tar --no-same-owner --no-same-permissions --delay-directory-restore -xzf /tmp/golang.tar.gz -C /usr/local || error_exit $LINENO
    rm -f /tmp/golang.tar.gz
    echo "GoLang downloaded and installed."
  fi
fi

# Set up GoLang environment variables globally
echo "Setting up GoLang environment variables globally..."
echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/profile
export PATH="$PATH:/usr/local/go/bin"

# Verify GoLang installation
if ! go version > /dev/null 2>&1; then
    echo "GoLang installation from tarball failed. Attempting to install via apt..."
    apt-get install -y golang || error_exit $LINENO
    verify_package_installation golang
fi

# Print the installed GoLang version
#echo "GoLang installation successful. Installed version:"
#go version || { echo "Failed to retrieve GoLang version!"; error_exit $LINENO; }
#echo "GoLang setup complete."
if command -v go >/dev/null 2>&1; then
  echo "GoLang installation successful. Installed version:"
  go version || true
else
  echo "GoLang not installed; skipping version check." >&2
fi
echo "GoLang setup complete."


# Optimize GoLang
# tee -a /etc/bash.bashrc > /dev/null <<'EOL'
tee -a /etc/bash.bashrc > /dev/null <<'EOL'
# --- BEGIN: Raspberry Pi 5 Go wrapper (system-wide) --------------------------
# WARNING / READ ME:
# - CGO: This wrapper forces CGO_ENABLED=0 for all go build/install/run/test.
#   Pure-Go projects link cleanly (often fully static with -extldflags=-static).
#   Any package requiring cgo will fail; 'go test -race' won't work.
# - Bounds checks: GOGCFLAGS default is now empty; to DISABLE bounds checks, set
#   GO_FAST_UNSAFE=1 (adds -gcflags=all=-B). Use only with thorough tests.
# - Static linking: we add -extldflags=-static by default. With CGO disabled,
#   fully static pure-Go binaries are generally reliable.
# - Reproducibility: we pass -trimpath, -buildvcs=false, and scope GOENV=off.
# - Performance / SD wear: build cache and temp dirs live in RAM (/dev/shm).
# - Escape hatch (bypass wrapper): run /usr/bin/go directly.
# ------------------------------------------------------------------------------

go() (
    if [ -z "${1:-}" ]; then
        echo "Usage: go <subcommand> [options]"
        return 1
    fi

    # Ensure the real 'go' binary exists (avoid recursion confusion)
    if ! type -P go >/dev/null 2>&1; then
        echo "go: binary not found in PATH. Install Go first." >&2
        return 127
    fi

    # Force pure-Go toolchain and avoid auto toolchain downloads (Go 1.21+)
    local _cgo_enabled=0
    local _gotoolchain="${GOTOOLCHAIN:-local}"

    # Raise only this subshell's soft limit; the caller's limits and traps stay intact.
    ulimit -Sn 8192 >/dev/null 2>&1 || true

    # Build cache and temp space in RAM (fallbacks if not available)
    local GOCACHE GOTMPDIR TMPDIR
    local _uid="${UID:-$(id -u)}"

    if [ -d /dev/shm ]; then
        GOCACHE="/dev/shm/go-build-${_uid}"
        GOTMPDIR="/dev/shm/go-tmp-${_uid}"
        TMPDIR="$GOTMPDIR"
        # Warn if /dev/shm low on free space (<200MB available)
        local shm_avail_kb
        shm_avail_kb=$(df -k --output=avail /dev/shm 2>/dev/null | awk 'NR==2{print $1}')
        if [ -z "$shm_avail_kb" ]; then
            # Fallback for df without --output
            shm_avail_kb=$(df -k /dev/shm 2>/dev/null | awk 'NR==2{print $4}')
        fi
        if [ -n "$shm_avail_kb" ] && [ "$shm_avail_kb" -lt 204800 ]; then
            echo "note: /dev/shm low on free space ($((shm_avail_kb/1024)) MB available); Go cache/tmp may evict often." >&2
        fi
        unset shm_avail_kb
    else
        GOCACHE="/tmp/go-build-${_uid}"
        GOTMPDIR="/tmp/go-tmp-${_uid}"
        TMPDIR="$GOTMPDIR"
    fi
    [ -d "$GOCACHE" ] || mkdir -m 700 -p "$GOCACHE"
    [ -d "$GOTMPDIR" ] || mkdir -m 700 -p "$GOTMPDIR"

    # Detect if caller already supplied -ldflags or -gcflags on the CLI
    local user_has_ldflags=0 user_has_gcflags=0
    for a in "$@"; do
        case "$a" in
            -ldflags|-ldflags=*) user_has_ldflags=1 ;;
            -gcflags|-gcflags=*) user_has_gcflags=1 ;;
        esac
    done
    # (#3) Respect GOFLAGS for the same decision
    case " ${GOFLAGS:-} " in
        *" -ldflags "*|*" -ldflags="*) user_has_ldflags=1 ;;
    esac
    case " ${GOFLAGS:-} " in
        *" -gcflags "*|*" -gcflags="*) user_has_gcflags=1 ;;
    esac

    # Defaults; can be overridden by env (and skipped if user set CLI/GOFLAGS)
    local ldflags_default="-s -w -extldflags=-static"
    local ldflags="${GOLDFLAGS:-$ldflags_default}"

    # (#6) Unsafe bounds-check removal is now opt-in via GO_FAST_UNSAFE=1
    local gcflags_default=""
    if [ "${GO_FAST_UNSAFE:-0}" = "1" ]; then
        gcflags_default="-B"
    fi
    local gcflags="${GOGCFLAGS:-$gcflags_default}"

    # Build flags for reproducibility; -mod applies only in module-aware mode.
    local -a buildflags=(-trimpath -buildvcs=false)
    if [ -n "$(GOENV="${GOENV:-off}" command go env GOMOD)" ]; then
        buildflags+=(-mod=readonly)
    fi

    # Compose args safely (preserve spaces); respect user CLI/GOFLAGS
    local -a common_args=()
    if [ $user_has_ldflags -eq 0 ]; then
        common_args+=("-ldflags=$ldflags")
    fi
    if [ -n "$gcflags" ] && [ $user_has_gcflags -eq 0 ]; then
        common_args+=("-gcflags=all=$gcflags")
    fi
    common_args+=("${buildflags[@]}")

    local subcommand="$1"; shift

    # (#7) Robust warning if -race is requested (won't work with CGO=0)
    for a in "$@"; do
        case "$a" in
            -race|-race=* ) echo "note: -race requires cgo; CGO_ENABLED=0 will cause this build to fail." >&2 ;;
        esac
    done

    if [ "${GO_VERBOSE:-0}" = "1" ]; then
        local goversion; goversion="$(GOENV="${GOENV:-off}" GOTOOLCHAIN="$_gotoolchain" command go version 2>/dev/null || echo unknown)"
        # Quote args robustly for logging
        local -a common_quoted=() args_quoted=()
        for a in "${common_args[@]}"; do common_quoted+=("$(printf '%q' "$a")"); done
        for a in "$@"; do args_quoted+=("$(printf '%q' "$a")"); done
        printf 'Running (%s): CGO_ENABLED=%s GOTOOLCHAIN=%s GOENV=%s GOCACHE=%q GOTMPDIR=%q TMPDIR=%q go %s %s %s\n' \
            "$goversion" "$_cgo_enabled" "$_gotoolchain" "${GOENV:-off}" "$GOCACHE" "$GOTMPDIR" "$TMPDIR" \
            "$subcommand" "${common_quoted[*]}" "${args_quoted[*]}"
    fi

    # Run the real go with scoped environment (includes #2 GOENV=off)
    local rc=0
    case "$subcommand" in
        build)
            GOENV="${GOENV:-off}" CGO_ENABLED="$_cgo_enabled" GOTOOLCHAIN="$_gotoolchain" \
            GOCACHE="$GOCACHE" GOTMPDIR="$GOTMPDIR" TMPDIR="$TMPDIR" \
                command go build   "${common_args[@]}" "$@"
            rc=$?
            ;;
        install)
            GOENV="${GOENV:-off}" CGO_ENABLED="$_cgo_enabled" GOTOOLCHAIN="$_gotoolchain" \
            GOCACHE="$GOCACHE" GOTMPDIR="$GOTMPDIR" TMPDIR="$TMPDIR" \
                command go install "${common_args[@]}" "$@"
            rc=$?
            ;;
        run)
            GOENV="${GOENV:-off}" CGO_ENABLED="$_cgo_enabled" GOTOOLCHAIN="$_gotoolchain" \
            GOCACHE="$GOCACHE" GOTMPDIR="$GOTMPDIR" TMPDIR="$TMPDIR" \
                command go run     "${common_args[@]}" "$@"
            rc=$?
            ;;
        test)
            GOENV="${GOENV:-off}" CGO_ENABLED="$_cgo_enabled" GOTOOLCHAIN="$_gotoolchain" \
            GOCACHE="$GOCACHE" GOTMPDIR="$GOTMPDIR" TMPDIR="$TMPDIR" \
                command go test    "${common_args[@]}" "$@"
            rc=$?
            ;;
        *)
            # Other subcommands (env, version, tool, mod, etc.)
            GOENV="${GOENV:-off}" CGO_ENABLED="$_cgo_enabled" GOTOOLCHAIN="$_gotoolchain" \
            GOCACHE="$GOCACHE" GOTMPDIR="$GOTMPDIR" TMPDIR="$TMPDIR" \
                command go "$subcommand" "$@"
            rc=$?
            ;;
    esac

    return $rc
)
# --- END: Raspberry Pi 5 Go wrapper ------------------------------------------
EOL

# Step 4: General Linux Performance Tools
echo "Installing general performance tools (linux-perf, htop, procps, sysstat, dstat, net-tools)..."
apt-get install -y linux-perf htop procps sysstat dstat net-tools || error_exit $LINENO
verify_package_installation linux-perf htop procps sysstat pcp net-tools

# Enable sysstat data collection
sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat || error_exit $LINENO
systemctl enable --now sysstat.service sysstat-collect.timer \
  sysstat-rotate.timer sysstat-summary.timer || error_exit $LINENO
echo "General performance tools installed successfully."

# Verify performance tools
which perf && echo "perf installed successfully" || { echo "perf installation failed"; error_exit $LINENO; }

# Step 5: Advanced Performance Tools
echo "Installing advanced performance tools (bpfcc-tools, bpftrace, strace, trace-cmd)..."
apt-get install -y bpfcc-tools bpftrace strace trace-cmd || error_exit $LINENO
verify_package_installation bpfcc-tools bpftrace strace trace-cmd
echo "Advanced performance tools installed successfully."

## Step 6: Profiling and Debugging Tools
#echo "Installing git and profiling/debugging tools (git, cppcheck, gprof, valgrind, gdb)..."
#apt-get install -y git || error_exit $LINENO
#verify_package_installation git
#apt-get install -y cppcheck gprof valgrind gdb || error_exit $LINENO
#verify_package_installation cppcheck gprof valgrind gdb
#git clone https://github.com/brendangregg/FlameGraph || error_exit $LINENO
#echo "Profiling and debugging tools installed successfully."

# Step 6: Profiling and Debugging Tools
echo "Installing profiling/debugging tools (cppcheck, gprof, valgrind, gdb) and FlameGraph..."
apt-get install -y cppcheck binutils valgrind gdb || error_exit $LINENO
verify_package_installation cppcheck binutils valgrind gdb

FLAMEGRAPH_DIR="/opt/FlameGraph"
install -d -m 0755 "$FLAMEGRAPH_DIR"
install -d -m 0755 /opt

fetch_flamegraph_tarball_into_dir() {
  local url="$1"
  local -a downloader
  [ -d "$FLAMEGRAPH_DIR" ] || install -d -m 0755 "$FLAMEGRAPH_DIR"
  if command -v curl >/dev/null 2>&1; then
    downloader=(curl -fsSL)
  elif command -v wget >/dev/null 2>&1; then
    downloader=(wget -qO-)
  else
    apt-get install -y curl || apt-get install -y wget || return 1
    if command -v curl >/dev/null 2>&1; then
      downloader=(curl -fsSL)
    else
      downloader=(wget -qO-)
    fi
  fi
  if command -v pigz >/dev/null 2>&1; then
    "${downloader[@]}" "$url" | tar --no-same-owner --no-same-permissions --delay-directory-restore -I pigz -x -f - --strip-components=1 -C "$FLAMEGRAPH_DIR" || return 1
  else
    "${downloader[@]}" "$url" | tar --no-same-owner --no-same-permissions --delay-directory-restore -xz -f - --strip-components=1 -C "$FLAMEGRAPH_DIR" || return 1
  fi
  return 0
}

# Try both common default branches (master/main)
if fetch_flamegraph_tarball_into_dir "https://codeload.github.com/brendangregg/FlameGraph/tar.gz/refs/heads/master"; then
  :
elif fetch_flamegraph_tarball_into_dir "https://codeload.github.com/brendangregg/FlameGraph/tar.gz/refs/heads/main"; then
  :
else
  TARBALL_FAILED=1
fi

# Fallback: shallow clone only if tarball route failed
if [ "${TARBALL_FAILED:-0}" = "1" ]; then
  echo "Tarball fetch failed; falling back to shallow git clone..."
  apt-get install -y git || error_exit $LINENO
  verify_package_installation git
  rm -rf -- "$FLAMEGRAPH_DIR"
  git clone --depth=1 --single-branch --no-tags --filter=blob:none \
    https://github.com/brendangregg/FlameGraph "$FLAMEGRAPH_DIR" || error_exit $LINENO
fi

# Friendly symlink if scripts expect ./FlameGraph in CWD
if [ ! -e FlameGraph ] && [ -d "$FLAMEGRAPH_DIR" ]; then
  ln -s "$FLAMEGRAPH_DIR" FlameGraph || true
fi

echo "Profiling and debugging tools installed successfully."


# Step 7: Other Useful Utilities
echo "Installing other useful utilities (iotop, iftop, ncdu)..."
apt-get install -y iotop iftop ncdu || error_exit $LINENO
verify_package_installation iotop iftop ncdu
echo "Other useful utilities installed successfully."

# Step 8: Time synchronization
echo "Enabling time synchronization..."
timedatectl set-ntp true || error_exit $LINENO
echo "Time synchronization enabled."

# Step 9: Final Update and Upgrade
echo "Performing final system upgrade..."
apt-get update && apt-get upgrade -y || error_exit $LINENO
echo "System upgraded successfully."

touch /run/billspi/reboot-required
exit 0
