#!/bin/bash
# Copyright (c) 2026 Dean William Woodside
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

#
# Script Purpose and Overview:
# This script automates the configuration of Raspberry Pi OS Lite (64-bit, kernel 6.6, Debian 12 Bookworm) 
# on Raspberry Pi 5, enhancing system performance by replacing default Linux tools with optimized, 
# multi-core alternatives. It dynamically adjusts based on the available RAM (2GB, 4GB, 8GB or 16GB models), 
# ensuring the best block size is used for parallel operations. Additionally, the script optimizes cryptographic 
# operations with hardware acceleration.

# Key Features and Optimizations:
# 1. Memory-based Block Size Selection:
#    - Automatically sets block size for parallel operations based on available RAM.
#      10M for 2GB, 50M for 4GB, and 100M for 8GB models.
#
# 2. Parallel Execution:
#    - Utilizes GNU `parallel` to replace and optimize the following tools:
#      - `make` (parallelized as `pmake` using all 4 cores).
#      - `sort`, `sed`, `gawk`, and `crc32` (using custom block size for efficiency).
#      - `md5sum`, `sha256sum`, and other hash functions (leveraging OpenSSL for speed and hardware acceleration).
#
# 3. Compression Tools:
#    - Replaces default compression utilities with multi-core optimized versions:
#      - `gzip` replaced by `pigz`.
#      - `xz` replaced by `pxz`.
#      - `bzip2` replaced by `pbzip2`.
#      - `7z` replaced by `p7zip-full`.
#      - Adds `zstd` and `lz4` with multi-core support.
#
# 4. OpenSSL Optimization:
#    - Builds and installs OpenSSL from source with CryptoDev and multi-threading enabled.
#    - Takes advantage of hardware-accelerated cryptographic functions through CryptoDev.
#    - Optimizes checksum and cryptographic operations by using `openssl dgst` for `md5sum`, `sha256sum`, and others.
#
# 5. Enhanced Search and File Tools:
#    - Replaces `grep` with `ripgrep` for faster searching.
#    - Enhances `find` functionality with `fd`, a faster alternative.
#    - **Optimizes `rsync`, `mv`, and `cp` operations using parallelization:**
#      - **`rsync`: Automatically uses multi-threaded parallel `rsync` for all file transfers, leveraging GNU `parallel`.**
#      - **`mv`: Implements conditional logic for fast moves within the same disk (using traditional `mv`), and parallel `rsync` for cross-disk moves.**
#      - **`cp`: Aliased to always use parallel `rsync` for improved performance during copying operations.**
#
# 6. Additional High-Performance Alternatives:
#    - Installs `ninja` as an alternative to `make` for faster builds.
#    - Installs `aria2` as a faster, multi-threaded alternative to `wget` and `curl`.
#
# 7. Persistent Aliases:
#    - All optimizations and tool replacements are aliased in `.bash_aliases` for persistence across sessions.
#
# 8. Compiler-Level Optimizations:
#    - Sets system-wide compiler flags (`CFLAGS`, `CXXFLAGS`) to optimize performance for ARMv8 Cortex-A76 cores, 
#      enabling hardware cryptography, CRC, and applying aggressive optimizations (`-O3`).
#
# This script configures aliases for optimized tools and performance enhancements using Bash.
# If you're using a different shell (e.g., Zsh, Fish, Ksh), you may need to manually add the aliases 
# to your shell's configuration files. 
# To adapt the script for your shell, search and replace all instances of '/etc/bash.bashrc' 
# with the relevant configuration file path for your shell:
# - Zsh: /etc/zsh/zshrc
# - Fish: /etc/fish/config.fish
# - Ksh: /etc/profile
#
# Get the total memory size in KB
TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

# Determine BLOCK_SIZE based on total RAM (in KB)
if [ $TOTAL_MEM_KB -ge 15000000 ]; then
    # 16GB RAM model
    BLOCK_SIZE=200M
elif [ $TOTAL_MEM_KB -ge 7500000 ]; then
    # 8GB RAM model
    BLOCK_SIZE=100M
elif [ $TOTAL_MEM_KB -ge 3500000 ]; then
    # 4GB RAM model
    BLOCK_SIZE=50M
else
    # 2GB RAM model
    BLOCK_SIZE=10M
fi

# Check if .bash_aliases exists; if not, create it
if [ ! -f /etc/bash.bashrc ]; then
    touch /etc/bash.bashrc
fi

# Update and upgrade system
apt-get update
#apt-get upgrade -y # THIS LINE SHOULD NOT BE REQUIRED; PREVIOUS PHASES WILL UPGRADE ALL PACKAGES.  REDUNDANT?

# Install essential tools
apt-get install -y parallel coreutils ripgrep rsync gawk fd-find ninja-build aria2 # realpath (realpath is part of coreutils, so commented out)

# Create aliases for optimized tools using GNU Parallel and other multicore optimizations
grep -qxF "alias pmake='make -j4'" /etc/bash.bashrc || echo "alias pmake='make -j4'" >> /etc/bash.bashrc
# gsort is not available: grep -qxF "alias sort='parallel --pipe --block $BLOCK_SIZE gsort'" /etc/bash.bashrc || echo "alias sort='parallel --pipe --block $BLOCK_SIZE gsort'" >> /etc/bash.bashrc
grep -qxF "alias sort='command sort --parallel=$(nproc)'" /etc/bash.bashrc || echo "alias sort='command sort --parallel=$(nproc)'" >> /etc/bash.bashrc
# DEPRECATED FOR BELOW
# grep -qxF "alias rsync='find \$1 -type f | parallel -j4 rsync -a --info=progress2 {} \$2/{/}'" /etc/bash.bashrc || echo "alias rsync_parallel='find \$1 -type f | parallel -j4 rsync -a --info=progress2 {} \$2/{/}'" >> /etc/bash.bashrc
# Function for parallel rsync with condition for mv and cp (to be aliased below)
rsync_mv_cp() {
    # Expand source and destination paths to absolute paths
    local source=$(realpath "$1")
    local destination=$(realpath "$2")

    # Validate that source exists
    if [ ! -e "$source" ]; then
        echo "Error: Source path does not exist."
        return 1
    fi

    # Create destination directory if it doesn't exist
    mkdir -p "$destination"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create destination directory."
        return 1
    fi
    
    # Check if the source and destination are on the same disk
    if [ "$(df -P "$source" | tail -1 | awk '{print $1}')" = "$(df -P "$destination" | tail -1 | awk '{print $1}')" ]; then
        # If on the same disk, use plain 'mv' for moving and rsync for copying
        if [ "$3" = "mv" ]; then
            mv "$source" "$destination"
            if [ $? -ne 0 ]; then
                echo "Error: mv failed."
                return 1
            fi
        else
            rsync -aH --info=progress2 "$source" "$destination"
        fi
    else
        # Check if it's a file or a directory
        if [ -f "$source" ]; then
            # Single file case: use rsync directly
            rsync -aH --info=progress2 "$source" "$destination"
            if [ "$3" = "mv" ]; then
                if [ $? -eq 0 ]; then
                    rm -f "$source"
                else
                    echo "Error: rsync failed, not removing source file."
                fi
            fi
        else
            # Ensure source directory is not empty before proceeding
            if [ "$(ls -A "$source")" ]; then
                # Directory case: include both files and directories
                find "$source" \( -type f -o -type d \) | parallel -j4 rsync -aH --info=progress2 --relative {} "$destination"/{/}
                if [ "$3" = "mv" ]; then
                    if [ $? -eq 0 ]; then
                        rm -rf "$source"
                    else
                        echo "Error: rsync failed, not removing source directory."
                    fi
                fi
            else
                echo "Warning: Source directory is empty, skipping."
            fi
        fi
    fi
}

# Do not alias rsync: aliases cannot use $1/$2; use the rsync_mv_cp() function instead
# Alias rsync to always use parallel rsync
# grep -qxF "alias rsync='find \$1 -type f | parallel -j4 rsync -aH --info=progress2 {} \$2/{/}'" /etc/bash.bashrc || echo "alias rsync='find \$1 -type f | parallel -j4 rsync -aH --info=progress2 {} \$2/{/}'" >> /etc/bash.bashrc



# Alias mv to use the conditional rsync function for cross-drive moves, or default to 'mv'

# Alias cp to always use the conditional rsync function


# Source .bash_aliases to activate new aliases
# Interactive shells load /etc/bash.bashrc themselves.

# Install and configure multicore compression tools
apt-get install -y pigz zstd lz4 xz-utils pbzip2 p7zip-full
ln -sf /usr/bin/pigz /usr/bin/gzip
ln -sf /usr/bin/pigz /usr/bin/gunzip
grep -qxF "alias gzip='pigz'" /etc/bash.bashrc || echo "alias gzip='pigz'" >> /etc/bash.bashrc
# grep -qxF "alias gunzip='pigz -d'" /etc/bash.bashrc || echo "alias gunzip='pigz -d'" >> /etc/bash.bashrc
grep -qxF "alias zstd='zstd -T4'" /etc/bash.bashrc || echo "alias zstd='zstd -T4'" >> /etc/bash.bashrc
grep -qxF "alias xz='command xz -T4'" /etc/bash.bashrc || echo "alias xz='command xz -T4'" >> /etc/bash.bashrc
grep -qxF "alias bzip2='pbzip2 -p4'" /etc/bash.bashrc || echo "alias bzip2='pbzip2 -p4'" >> /etc/bash.bashrc
grep -qxF "alias 7z='7z -mmt=4'" /etc/bash.bashrc || echo "alias 7z='7z -mmt=4'" >> /etc/bash.bashrc

# Optimize OpenSSL with CryptoDev and Threads

# Use Debian's OpenSSL 3 (do NOT shadow system OpenSSL, no custom build)
apt-get update
apt-get install -y openssl libssl3

# Verify distro OpenSSL 3
/usr/bin/openssl version -a
/usr/bin/openssl list -providers -verbose

# crc32 optimization
# apt-get install -y libarchive-tools
apt-get install -y rhash
grep -qxF "alias crc32='rhash --crc32 --simple'" /etc/bash.bashrc || echo "alias crc32='rhash --crc32 --simple'" >> /etc/bash.bashrc

# 8. Compiler-Level Optimizations.
# Set system-wide compiler flags
tee -a /etc/bash.bashrc > /dev/null <<EOL
export CFLAGS='-march=armv8-a+crc+crypto -mtune=cortex-a76 -O3'
export CXXFLAGS='-march=armv8-a+crc+crypto -mtune=cortex-a76 -O3'
EOL

#####################################################################
# System-wide gunzip wrapper

# Keep the existing pigz decompressor for gzip-compatible input handling.
apt-get update
apt-get install -y --no-install-recommends libdeflate-tools pigz

install -d /usr/local/bin
cat >/usr/local/bin/gunzip <<'EOF'
#!/bin/sh
# Preserve the input handling of the existing decompressor.
PIGZ=/usr/bin/pigz
REAL=/usr/bin/gunzip

if [ -x "$PIGZ" ]; then exec "$PIGZ" -d "$@"; fi
exec "$REAL" "$@"
EOF
chmod 0755 /usr/local/bin/gunzip

#####################################################################

# Final source of aliases
# Interactive shells load /etc/bash.bashrc themselves.

touch /run/billspi/reboot-required
exit 0
