#!/bin/bash
# Automated HDD Migration Tool with SSH Credentials
# ---------------------------------------------------------
# WARNING: This script performs raw disk cloning.
# Ensure you have backups and test in a safe environment.
# Both systems must have SSH access with sufficient privileges.
# ---------------------------------------------------------

set -e

##############################
# Helper Functions
##############################

# remote_ssh: Executes a command on the remote host.
# Uses sshpass if a destination password was provided and sshpass is installed.
remote_ssh() {
    if [ -n "$dest_pass" ] && command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$dest_pass" ssh "$dest_user@$dest_host" "$@"
    else
        ssh "$dest_user@$dest_host" "$@"
    fi
}

# Install netcat on the local system (Debian-based: netcat-openbsd, RHEL-based: nmap-ncat)
install_netcat_local() {
    if ! command -v nc >/dev/null 2>&1; then
        echo "[Local] netcat not found. Attempting installation..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y netcat-openbsd
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nmap-ncat
        else
            echo "[Local] Unsupported package manager. Please install netcat manually."
            exit 1
        fi
    else
        echo "[Local] netcat is already installed."
    fi
}

# Install netcat on the remote host via SSH
install_netcat_remote() {
    remote_ssh "if ! command -v nc >/dev/null 2>&1; then
        echo 'netcat not found on remote. Attempting installation...';
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y netcat-openbsd;
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nmap-ncat;
        else
            echo 'Unsupported package manager on remote. Install netcat manually.'; exit 1;
        fi;
    else
        echo 'netcat is already installed on remote.';
    fi"
}

# List disks using lsblk (shows disks and partitions)
list_disks() {
    echo "------------------------------"
    lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT
    echo "------------------------------"
}

##############################
# Main Script
##############################

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1
fi

# Install netcat locally if missing
install_netcat_local

# List available disks on the source system
echo "Source system disk configuration:"
list_disks

# Prompt user for source disk selection (e.g., sda)
read -rp "Enter the source disk (e.g., sda): " src_disk
src_path="/dev/${src_disk}"

# Verify source disk exists
if [ ! -b "$src_path" ]; then
    echo "Source disk $src_path does not exist."
    exit 1
fi

# Get source disk size in bytes
src_size=$(blockdev --getsize64 "$src_path")
echo "Selected source disk: $src_path (Size: $src_size bytes)"

# Get destination SSH information
read -rp "Enter destination host (IP or hostname): " dest_host
read -rp "Enter destination SSH username: " dest_user
read -srp "Enter destination SSH password (leave empty to use interactive prompt or SSH keys): " dest_pass
echo

# (Optional) netcat transfer port (default: 9000)
default_port=9000
read -rp "Enter netcat transfer port [${default_port}]: " nc_port
nc_port=${nc_port:-$default_port}

# Check/install netcat on destination
echo "[Remote] Checking netcat installation on ${dest_host}..."
install_netcat_remote

# List disks on the destination system via SSH
echo "[Remote] Disk configuration on destination (${dest_host}):"
remote_ssh "bash -c '$(declare -f list_disks); list_disks'"

# Prompt user for destination disk selection (e.g., sda)
read -rp "Enter the destination disk on remote (e.g., sda): " dest_disk
dest_path="/dev/${dest_disk}"

# Verify destination disk exists on remote
remote_ssh "test -b ${dest_path}" || { echo "Destination disk ${dest_path} not found on remote."; exit 1; }

# Get destination disk size (in bytes) from remote
dest_size=$(remote_ssh "blockdev --getsize64 ${dest_path}")
echo "Selected destination disk: ${dest_path} (Size: ${dest_size} bytes)"

# Validate that destination disk is at least as big as the source disk
if [ "$src_size" -gt "$dest_size" ]; then
    echo "Error: Source disk size ($src_size bytes) is larger than destination disk size ($dest_size bytes). Aborting."
    exit 1
fi

echo "Disk size validation passed."

# Confirm with the user before starting migration
read -rp "Proceed with cloning $src_path to ${dest_user}@${dest_host}:${dest_path}? (yes/no): " confirmation
if [[ "$confirmation" != "yes" ]]; then
    echo "Operation cancelled by user."
    exit 0
fi

# Start remote dd (destination) via netcat listener in the background.
# The remote SSH user must have sufficient privileges to write to $dest_path.
echo "Starting destination listener..."
remote_ssh "nohup bash -c 'nc -l -p ${nc_port} -q 1 | dd of=${dest_path} bs=64K' > /tmp/dd_migrate.log 2>&1 &"

# Wait a few seconds to ensure the remote listener is up
sleep 3

# Start local dd to send disk data over netcat
echo "Starting disk transfer from source..."
dd if="${src_path}" bs=64K status=progress | nc "${dest_host}" "${nc_port}"

echo "Migration completed. Please check /tmp/dd_migrate.log on the destination for details."
