#!/bin/bash
# Enhanced Automated HDD Migration Tool with SSH Credentials
# ---------------------------------------------------------
# WARNING: This script performs raw disk cloning.
# Ensure you have backups and test in a safe environment.
# Both systems must have SSH access with sufficient privileges.
# ---------------------------------------------------------

set -e 
set -o pipefail  # Better error handling for pipelines

# Version
VERSION="2.0.0"

##############################
# Global Variables
##############################
LOG_FILE="/var/log/disk-migration-$(date +%Y%m%d-%H%M%S).log"
CONFIG_DIR="$HOME/.config/disk-migration"
CONFIG_FILE="$CONFIG_DIR/config.conf"
VERBOSE=0
DRY_RUN=0
COMPRESSION=0
VALIDATE=0
BLOCK_SIZE="64K"
BANDWIDTH_LIMIT=""
DEFAULT_PORT=9000
ENCRYPT_TRANSFER=0
USE_LVM_SNAPSHOT=0
NOTIFICATION_EMAIL=""
SNAPSHOT_NAME="disk_migration_snapshot"
CONTINUE_TRANSFER=0
TRANSFER_OFFSET=0

##############################
# Helper Functions
##############################

# Logging function with severity levels
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case $level in
        INFO)    local prefix="[INFO]" ;;
        WARNING) local prefix="[WARNING]" ;;
        ERROR)   local prefix="[ERROR]" ;;
        DEBUG)   
            if [ "$VERBOSE" -eq 1 ]; then
                local prefix="[DEBUG]"
            else
                return 0
            fi
            ;;
        *)       local prefix="[LOG]" ;;
    esac
    
    echo "$timestamp $prefix $message" | tee -a "$LOG_FILE"
}

# Display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Disk Migration Tool $VERSION - Safely clone disks over SSH

OPTIONS:
  -h, --help                Show this help message
  -c, --config FILE         Use specific config file
  -s, --source DISK         Source disk (e.g., sda)
  -d, --dest DISK           Destination disk
  -H, --host HOST           Destination host
  -u, --user USER           SSH username
  -p, --port PORT           SSH port (default: 22)
  -t, --transfer-port PORT  Data transfer port (default: $DEFAULT_PORT)
  -b, --block-size SIZE     Block size for dd (default: $BLOCK_SIZE)
  -l, --limit RATE          Bandwidth limit (e.g., 10M)
  -v, --verbose             Enable verbose output
  --compress                Enable compression during transfer
  --validate                Verify transfer with checksums
  --encrypt                 Encrypt data during transfer
  --dry-run                Show commands without executing
  --snapshot                Use LVM snapshot for live migration
  --continue                Continue interrupted transfer
  --offset BYTES            Starting offset for continued transfer
  --notify EMAIL            Email to notify on completion

Examples:
  $0 -s sda -d sdb -H remote.host -u admin --validate
  $0 --compress --snapshot --config my-config.conf

EOF
    exit 1
}

# remote_ssh: Executes a command on the remote host.
# Uses sshpass if a destination password was provided and sshpass is installed.
remote_ssh() {
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    
    if [ -n "$ssh_port" ] && [ "$ssh_port" != "22" ]; then
        ssh_opts="$ssh_opts -p $ssh_port"
    fi
    
    if [ -n "$dest_pass" ] && command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$dest_pass" ssh $ssh_opts "$dest_user@$dest_host" "$@"
    else
        ssh $ssh_opts "$dest_user@$dest_host" "$@"
    fi
}

# remote_scp: Copies a file to the remote host
remote_scp() {
    local src="$1"
    local dst="$2"
    local scp_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
    
    if [ -n "$ssh_port" ] && [ "$ssh_port" != "22" ]; then
        scp_opts="$scp_opts -P $ssh_port"
    fi
    
    if [ -n "$dest_pass" ] && command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$dest_pass" scp $scp_opts "$src" "$dest_user@$dest_host:$dst"
    else
        scp $scp_opts "$src" "$dest_user@$dest_host:$dst"
    fi
}

# Install a package if it's not already installed
install_package() {
    local package="$1"
    
    if ! command -v "$package" >/dev/null 2>&1; then
        log "INFO" "Package $package not found. Attempting installation..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y "$package"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$package"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$package"
        else
            log "ERROR" "Unsupported package manager. Please install $package manually."
            exit 1
        fi
    else
        log "DEBUG" "$package is already installed."
    fi
}

# Install netcat on the local system
install_netcat_local() {
    if ! command -v nc >/dev/null 2>&1; then
        log "INFO" "Installing netcat locally..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y netcat-openbsd
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nmap-ncat
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y nmap-ncat
        else
            log "ERROR" "Unsupported package manager. Please install netcat manually."
            exit 1
        fi
    else
        log "DEBUG" "netcat is already installed locally."
    fi
    
    # Install pv (pipe viewer) for progress monitoring if needed
    if [ -n "$BANDWIDTH_LIMIT" ] || [ "$VERBOSE" -eq 1 ]; then
        install_package "pv"
    fi
    
    # Install mbuffer for better buffering
    install_package "mbuffer"
    
    # If compression is enabled, ensure gzip is installed
    if [ "$COMPRESSION" -eq 1 ]; then
        install_package "gzip"
    fi
}

# Install netcat on the remote host via SSH
install_netcat_remote() {
    log "INFO" "Checking for netcat on remote host..."
    
    remote_ssh "if ! command -v nc >/dev/null 2>&1; then
        echo 'netcat not found on remote. Attempting installation...';
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y netcat-openbsd;
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nmap-ncat;
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y nmap-ncat;
        else
            echo 'Unsupported package manager on remote. Install netcat manually.'; exit 1;
        fi;
    else
        echo 'netcat is already installed on remote.';
    fi"
    
    # Install additional required packages on remote
    if [ "$COMPRESSION" -eq 1 ]; then
        log "INFO" "Checking for gzip on remote host..."
        remote_ssh "command -v gzip >/dev/null 2>&1 || { 
            if command -v apt-get >/dev/null 2>&1; then 
                apt-get update && apt-get install -y gzip; 
            elif command -v yum >/dev/null 2>&1; then 
                yum install -y gzip; 
            elif command -v dnf >/dev/null 2>&1; then 
                dnf install -y gzip; 
            else 
                echo 'Cannot install gzip, please install manually.'; 
                exit 1; 
            fi; 
        }"
    fi
    
    if [ "$VALIDATE" -eq 1 ]; then
        log "INFO" "Checking for md5sum on remote host..."
        remote_ssh "command -v md5sum >/dev/null 2>&1 || {
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update && apt-get install -y coreutils;
            elif command -v yum >/dev/null 2>&1; then
                yum install -y coreutils;
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y coreutils;
            else
                echo 'Cannot install md5sum, please install manually.';
                exit 1;
            fi;
        }"
    fi
}

# List disks using lsblk (shows disks and partitions)
list_disks() {
    echo "------------------------------"
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT
    else
        echo "lsblk not found, using fdisk instead:"
        fdisk -l | grep '^Disk /dev/'
    fi
    echo "------------------------------"
}

# Check if a disk is mounted
is_mounted() {
    local disk="$1"
    local grep_pattern="^/dev/${disk}[0-9]*"
    
    if mount | grep -qE "$grep_pattern"; then
        return 0  # Return 0 in bash means true
    else
        return 1  # Return non-zero in bash means false
    fi
}

# Create an LVM snapshot if needed
create_lvm_snapshot() {
    local disk="$1"
    local vg_name
    local lv_name
    
    # Check if this is an LVM volume
    if ! lvs --noheadings -o vg_name,lv_name,lv_path | grep -q "/dev/${disk}"; then
        log "ERROR" "$disk does not appear to be an LVM logical volume."
        exit 1
    fi
    
    # Get VG and LV names
    vg_name=$(lvs --noheadings -o vg_name "/dev/${disk}" | tr -d ' ')
    lv_name=$(lvs --noheadings -o lv_name "/dev/${disk}" | tr -d ' ')
    
    log "INFO" "Creating LVM snapshot of /dev/${disk} (${vg_name}/${lv_name})..."
    
    # Create the snapshot with 10% of the original volume size or 10GB, whichever is smaller
    local lv_size=$(lvs --noheadings --units g -o lv_size "/dev/${disk}" | tr -d ' G')
    local snap_size=$(echo "scale=0; if($lv_size * 0.1 > 10) 10 else $lv_size * 0.1" | bc)
    
    lvcreate -s -n "$SNAPSHOT_NAME" -L "${snap_size}G" "/dev/${vg_name}/${lv_name}"
    
    # Return the path to the snapshot
    echo "/dev/${vg_name}/${SNAPSHOT_NAME}"
}

# Remove LVM snapshot when done
remove_lvm_snapshot() {
    local vg_name="$1"
    
    log "INFO" "Removing LVM snapshot ${vg_name}/${SNAPSHOT_NAME}..."
    lvremove -f "${vg_name}/${SNAPSHOT_NAME}"
}

# Calculate checksum for a block device
calculate_checksum() {
    local device="$1"
    local bs="$2"
    local count="$3"
    
    # For block devices, we calculate checksums in chunks to avoid reading the entire device
    local chunk_size="1G"
    local cmd="dd if='$device' bs=$bs count=$count | md5sum | cut -d' ' -f1"
    
    log "INFO" "Calculating checksum for $device..."
    
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "00000000000000000000000000000000"  # Dummy checksum for dry run
    else
        eval "$cmd"
    fi
}

# Send notification email if configured
send_notification() {
    local subject="$1"
    local message="$2"
    
    if [ -n "$NOTIFICATION_EMAIL" ] && command -v mail >/dev/null 2>&1; then
        log "INFO" "Sending notification email to $NOTIFICATION_EMAIL"
        if [ "$DRY_RUN" -eq 0 ]; then
            echo "$message" | mail -s "$subject" "$NOTIFICATION_EMAIL"
        else
            log "DEBUG" "Would send email with subject: $subject"
            log "DEBUG" "Email content: $message" 
        fi
    fi
}

# Save transfer state for resumption
save_transfer_state() {
    local offset="$1"
    local state_file="$CONFIG_DIR/transfer_state.json"
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$state_file" << EOF
{
  "timestamp": "$(date +%s)",
  "source": "$src_disk",
  "destination": "$dest_disk",
  "host": "$dest_host",
  "offset": $offset,
  "total_size": $src_size
}
EOF

    log "INFO" "Transfer state saved to $state_file"
}

# Load saved transfer state
load_transfer_state() {
    local state_file="$CONFIG_DIR/transfer_state.json"
    
    if [ ! -f "$state_file" ]; then
        log "ERROR" "No saved transfer state found at $state_file"
        exit 1
    fi
    
    # Extract values using grep and cut (bash-friendly approach)
    TRANSFER_OFFSET=$(grep -o '"offset": [0-9]*' "$state_file" | cut -d' ' -f2)
    local saved_source=$(grep -o '"source": "[^"]*"' "$state_file" | cut -d'"' -f4)
    local saved_dest=$(grep -o '"destination": "[^"]*"' "$state_file" | cut -d'"' -f4)
    local saved_host=$(grep -o '"host": "[^"]*"' "$state_file" | cut -d'"' -f4)
    
    # Validate loaded state matches current parameters
    if [ "$saved_source" != "$src_disk" ] || [ "$saved_dest" != "$dest_disk" ] || [ "$saved_host" != "$dest_host" ]; then
        log "ERROR" "Current parameters don't match saved state. Cannot resume transfer."
        log "ERROR" "Saved: $saved_source -> $saved_host:$saved_dest, Current: $src_disk -> $dest_host:$dest_disk"
        exit 1
    fi
    
    log "INFO" "Resuming transfer from offset $TRANSFER_OFFSET bytes"
}

# Backup MBR/partition table before overwriting
backup_disk_metadata() {
    local disk="$1"
    local backup_dir="/tmp/disk-migration-backup"
    local backup_file="${backup_dir}/$(basename $disk)-mbr-$(date +%Y%m%d-%H%M%S).img"
    
    mkdir -p "$backup_dir"
    
    log "INFO" "Backing up MBR/partition table of $disk to $backup_file"
    
    if [ "$DRY_RUN" -eq 0 ]; then
        # Backup the first 1MB which includes MBR/GPT and partition table
        dd if="$disk" of="$backup_file" bs=1M count=1
    else
        log "DEBUG" "Would execute: dd if=$disk of=$backup_file bs=1M count=1"
    fi
}

# Load configuration from file
load_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log "WARNING" "Config file $config_file not found."
        return 1
    fi
    
    log "INFO" "Loading configuration from $config_file"
    
    # Source the config file (assumes bash-compatible syntax)
    # shellcheck disable=SC1090
    source "$config_file"
    
    return 0
}

# Create default configuration file
create_default_config() {
    if [ -f "$CONFIG_FILE" ]; then
        return
    fi
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_FILE" << EOF
# Disk Migration Tool Configuration

# Transfer Settings
BLOCK_SIZE="64K"      # Block size for dd
DEFAULT_PORT=9000     # Default netcat port
COMPRESSION=0         # Enable compression (0=off, 1=on)
VALIDATE=0            # Validate transfer with checksums
ENCRYPT_TRANSFER=0    # Encrypt data during transfer
#BANDWIDTH_LIMIT="10M" # Limit bandwidth (e.g., 10M, 1G)

# SSH Settings
#dest_host="server.example.com"  # Destination host
#dest_user="admin"               # SSH username
#ssh_port="22"                   # SSH port

# LVM Settings
USE_LVM_SNAPSHOT=0    # Use LVM snapshot for live migration
SNAPSHOT_NAME="disk_migration_snapshot"

# Notification Settings
#NOTIFICATION_EMAIL="admin@example.com"  # Email for notifications
EOF

    log "INFO" "Created default configuration file at $CONFIG_FILE"
}

##############################
# Main Script
##############################

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
log "INFO" "Disk Migration Tool $VERSION starting"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    log "ERROR" "Please run this script as root."
    exit 1
fi

# Create default config if it doesn't exist
create_default_config

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -c|--config)
            custom_config="$2"
            shift 2
            ;;
        -s|--source)
            src_disk="$2"
            shift 2
            ;;
        -d|--dest)
            dest_disk="$2"
            shift 2
            ;;
        -H|--host)
            dest_host="$2"
            shift 2
            ;;
        -u|--user)
            dest_user="$2"
            shift 2
            ;;
        -p|--port)
            ssh_port="$2"
            shift 2
            ;;
        -t|--transfer-port)
            nc_port="$2"
            shift 2
            ;;
        -b|--block-size)
            BLOCK_SIZE="$2"
            shift 2
            ;;
        -l|--limit)
            BANDWIDTH_LIMIT="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --compress)
            COMPRESSION=1
            shift
            ;;
        --validate)
            VALIDATE=1
            shift
            ;;
        --encrypt)
            ENCRYPT_TRANSFER=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --snapshot)
            USE_LVM_SNAPSHOT=1
            shift
            ;;
        --continue)
            CONTINUE_TRANSFER=1
            shift
            ;;
        --offset)
            TRANSFER_OFFSET="$2"
            shift 2
            ;;
        --notify)
            NOTIFICATION_EMAIL="$2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            usage
            ;;
    esac
done

# Load config file (default or specified)
if [ -n "$custom_config" ]; then
    load_config "$custom_config"
else
    load_config "$CONFIG_FILE"
fi

# Continue interrupted transfer if requested
if [ "$CONTINUE_TRANSFER" -eq 1 ] && [ "$TRANSFER_OFFSET" -eq 0 ]; then
    load_transfer_state
fi

# Install netcat locally if missing
install_netcat_local

# Interactive mode if parameters not provided via command line or config
if [ -z "$src_disk" ]; then
    # List available disks on the source system
    log "INFO" "Source system disk configuration:"
    list_disks
    
    # Prompt user for source disk selection (e.g., sda)
    read -rp "Enter the source disk (e.g., sda): " src_disk
fi

src_path="/dev/${src_disk}"

# Verify source disk exists
if [ ! -b "$src_path" ]; then
    log "ERROR" "Source disk $src_path does not exist."
    exit 1
fi

# Check if source disk is mounted and warn user
if is_mounted "$src_disk"; then
    log "WARNING" "Source disk $src_disk has mounted partitions! This may cause data corruption."
    read -rp "Do you want to proceed anyway? (yes/no): " mounted_confirmation
    if [[ "$mounted_confirmation" != "yes" ]]; then
        if [ "$USE_LVM_SNAPSHOT" -eq 1 ]; then
            log "INFO" "Will attempt to use LVM snapshot for safe migration."
        else
            log "ERROR" "Operation cancelled. Consider using --snapshot for live migration."
            exit 1
        fi
    fi
fi

# Get source disk size in bytes
src_size=$(blockdev --getsize64 "$src_path")
log "INFO" "Selected source disk: $src_path (Size: $src_size bytes)"

# Back up the source disk's MBR/partition table
backup_disk_metadata "$src_path"

# Use LVM snapshot if requested and needed
src_snapshot=""
if [ "$USE_LVM_SNAPSHOT" -eq 1 ]; then
    if is_mounted "$src_disk"; then
        src_snapshot=$(create_lvm_snapshot "$src_disk")
        src_path="$src_snapshot"
        log "INFO" "Using LVM snapshot $src_snapshot for migration"
    else
        log "INFO" "Disk is not mounted, LVM snapshot not needed"
    fi
fi

# Get destination SSH information
if [ -z "$dest_host" ]; then
    read -rp "Enter destination host (IP or hostname): " dest_host
fi

if [ -z "$dest_user" ]; then
    read -rp "Enter destination SSH username: " dest_user
fi

# Only ask for password if not already set in config
if [ -z "$dest_pass" ]; then
    read -srp "Enter destination SSH password (leave empty to use SSH keys): " dest_pass
    echo
fi

# Set default SSH port if not specified
ssh_port="${ssh_port:-22}"

# Set netcat port if not specified
nc_port="${nc_port:-$DEFAULT_PORT}"

# Check/install netcat on destination
log "INFO" "Checking netcat installation on ${dest_host}..."
install_netcat_remote

# List disks on the destination system via SSH
log "INFO" "Disk configuration on destination (${dest_host}):"
remote_ssh "bash -c '$(declare -f list_disks); list_disks'"

# Prompt user for destination disk selection if not provided
if [ -z "$dest_disk" ]; then
    read -rp "Enter the destination disk on remote (e.g., sda): " dest_disk
fi

dest_path="/dev/${dest_disk}"

# Verify destination disk exists on remote
remote_ssh "test -b ${dest_path}" || { log "ERROR" "Destination disk ${dest_path} not found on remote."; exit 1; }

# Check if destination disk is mounted and warn user
remote_ssh "bash -c '$(declare -f is_mounted); if is_mounted \"$dest_disk\"; then echo \"WARNING: Destination disk has mounted partitions\"; exit 1; else exit 0; fi'" || {
    log "WARNING" "Destination disk $dest_disk has mounted partitions! This may cause data corruption."
    read -rp "Do you want to proceed anyway? (yes/no): " dest_mounted_confirmation
    if [[ "$dest_mounted_confirmation" != "yes" ]]; then
        log "ERROR" "Operation cancelled."
        exit 1
    fi
}

# Get destination disk size (in bytes) from remote
dest_size=$(remote_ssh "blockdev --getsize64 ${dest_path}")
log "INFO" "Selected destination disk: ${dest_path} (Size: ${dest_size} bytes)"

# Create backup of destination disk's MBR/partition table on remote
if [ "$DRY_RUN" -eq 0 ]; then
    remote_ssh "mkdir -p /tmp/disk-migration-backup && dd if=${dest_path} of=/tmp/disk-migration-backup/\$(basename ${dest_path})-mbr-\$(date +%Y%m%d-%H%M%S).img bs=1M count=1"
else
    log "DEBUG" "Would backup destination disk MBR/partition table"
fi

# Validate that destination disk is at least as big as the source disk
if [ "$src_size" -gt "$dest_size" ]; then
    log "ERROR" "Source disk size ($src_size bytes) is larger than destination disk size ($dest_size bytes). Aborting."
    exit 1
fi

log "INFO" "Disk size validation passed."

# Calculate transfer size accounting for offset if resuming
transfer_size=$((src_size - TRANSFER_OFFSET))
if [ "$TRANSFER_OFFSET" -gt 0 ]; then
    log "INFO" "Resuming transfer from offset $TRANSFER_OFFSET, remaining: $transfer_size bytes"
fi

# Confirm with the user before starting migration
if [ "$DRY_RUN" -eq 0 ]; then
    read -rp "Proceed with cloning $src_path to ${dest_user}@${dest_host}:${dest_path}? (yes/no): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        log "INFO" "Operation cancelled by user."
        
        # Clean up LVM snapshot if created
        if [ -n "$src_snapshot" ]; then
            vg_name=$(lvs --noheadings -o vg_name "$src_snapshot" | tr -d ' ')
            remove_lvm_snapshot "$vg_name"
        fi
        
        exit 0
    fi
else
    log "INFO" "DRY RUN mode - no data will be transferred"
fi

# Start the clock for timing the transfer
start_time=$(date +%s)

# Prepare transfer command based on options
sender_cmd="dd if=\"${src_path}\" bs=${BLOCK_SIZE} skip=$((TRANSFER_OFFSET / $(numfmt --from=iec "${BLOCK_SIZE}"))) status=progress"
receiver_cmd="dd of=${dest_path} bs=${BLOCK_SIZE} seek=$((TRANSFER_OFFSET / $(numfmt --from=iec "${BLOCK_SIZE}"))) conv=notrunc"

# Add compression if enabled
if [ "$COMPRESSION" -eq 1 ]; then
    sender_cmd="$sender_cmd | gzip -c"
    receiver_cmd="gunzip -c | $receiver_cmd"
    log "INFO" "Compression enabled for transfer"
fi

# Add bandwidth limiting if specified
if [ -n "$BANDWIDTH_LIMIT" ]; then
    sender_cmd="$sender_cmd | pv -L $BANDWIDTH_LIMIT"
    log "INFO" "Bandwidth limited to $BANDWIDTH_LIMIT"
else
    # Add progress monitoring anyway if verbose
    if [ "$VERBOSE" -eq 1 ]; then
        sender_cmd="$sender_cmd | pv"
    fi
fi

# Add encryption if enabled (using openssl)
if [ "$ENCRYPT_TRANSFER" -eq 1 ]; then
    # Generate a random passphrase for encryption
    enc_passphrase=$(openssl rand -hex 16)
    
    # Store passphrase in temporary file for openssl
    echo "$enc_passphrase" > /tmp/enc_pass.tmp
    chmod 600 /tmp/enc_pass.tmp
    
    # Modify commands to use openssl
    sender_cmd="$sender_cmd | openssl enc -aes-256-cbc -pbkdf2 -pass file:/tmp/enc_pass.tmp"
    receiver_cmd="openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/tmp/enc_pass.tmp | $receiver_cmd"
    
    # Copy passphrase to remote host
    if [ "$DRY_RUN" -eq 0 ]; then
        remote_ssh "cat > /tmp/enc_pass.tmp" < /tmp/enc_pass.tmp
        remote_ssh "chmod 600 /tmp/enc_pass.tmp"
    else
        log "DEBUG" "Would transfer encryption passphrase to remote host"
    fi
    
    log "INFO" "Encryption enabled for transfer using AES-256-CBC"
fi

# Start remote dd (destination) via netcat listener in the background.
log "INFO" "Starting destination listener..."
if [ "$DRY_RUN" -eq 0 ]; then
    remote_ssh "nohup bash -c 'nc -l -p ${nc_port} -q 1 | ${receiver_cmd}' > /tmp/dd_migrate.log 2>&1 &"
else
    log "DEBUG" "Would execute on remote: nc -l -p ${nc_port} -q 1 | ${receiver_cmd}"
fi

# Wait a few seconds to ensure the remote listener is up
sleep 3

# Start local dd to send disk data over netcat
log "INFO" "Starting disk transfer from source..."
transfer_command="${sender_cmd} | nc \"${dest_host}\" \"${nc_port}\""

if [ "$DRY_RUN" -eq 0 ]; then
    # Save progress periodically in the background for resume capability
    (
        while true; do
            sleep 30
            # Get current progress from dd status if possible, otherwise estimate
            if [ -n "$(pgrep -f "dd if=${src_path}")" ]; then
                current_offset=$(kill -USR1 "$(pgrep -f "dd if=${src_path}")" 2>/dev/null || echo "0")
                if [ "$current_offset" != "0" ]; then
                    save_transfer_state "$current_offset"
                fi
            fi
        done
    ) &
    progress_pid=$!
    
    # Execute the transfer
    eval "$transfer_command"
    transfer_result=$?
    
    # Kill the progress monitoring process
    kill $progress_pid 2>/dev/null || true
    
    # Calculate transfer time
    end_time=$(date +%s)
    transfer_time=$((end_time - start_time))
    transfer_speed=$(echo "scale=2; $transfer_size / $transfer_time / 1024 / 1024" | bc)
    
    log "INFO" "Transfer completed in ${transfer_time}s (${transfer_speed} MB/s)"
    
    # Delete the transfer state file if transfer completed successfully
    if [ "$transfer_result" -eq 0 ]; then
        rm -f "$CONFIG_DIR/transfer_state.json"
    fi
else
    log "DEBUG" "Would execute: $transfer_command"
fi

# Validate the transfer if requested
if [ "$VALIDATE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    log "INFO" "Validating transfer with checksums (this may take a while)..."
    
    # Calculate checksum for a sample of the transferred data
    sample_size="1G"  # Sample size for validation
    sample_bs="1M"
    sample_count=$(($(numfmt --from=iec "${sample_size}") / $(numfmt --from=iec "${sample_bs}")))
    
    # Choose 3 different areas to validate: beginning, middle, and end
    for position in "start" "middle" "end"; do
        case $position in
            start)
                skip=0
                ;;
            middle)
                skip=$((src_size / 2 / $(numfmt --from=iec "${sample_bs}")))
                ;;
            end)
                skip=$(((src_size - $(numfmt --from=iec "${sample_size}")) / $(numfmt --from=iec "${sample_bs}")))
                ;;
        esac
        
        log "INFO" "Validating $position of disk..."
        
        # Calculate checksum on source
        src_sum=$(dd if="$src_path" bs="$sample_bs" skip="$skip" count="$sample_count" status=none | md5sum | cut -d ' ' -f1)
        
        # Calculate checksum on destination
        dest_sum=$(remote_ssh "dd if=${dest_path} bs=${sample_bs} skip=${skip} count=${sample_count} status=none | md5sum | cut -d ' ' -f1")
        
        if [ "$src_sum" = "$dest_sum" ]; then
            log "INFO" "Checksum validation passed for $position section: $src_sum"
        else
            log "ERROR" "Checksum validation FAILED for $position section!"
            log "ERROR" "Source: $src_sum"
            log "ERROR" "Destination: $dest_sum"
            validation_failed=1
        fi
    done
    
    if [ -n "$validation_failed" ]; then
        log "ERROR" "Transfer validation failed! Data may be corrupted."
        send_notification "Disk Migration Failed" "Disk migration from $src_path to $dest_host:$dest_path failed validation."
    else
        log "INFO" "Transfer validation passed successfully for all sample sections."
    fi
fi

# Clean up
if [ "$ENCRYPT_TRANSFER" -eq 1 ]; then
    rm -f /tmp/enc_pass.tmp
    remote_ssh "rm -f /tmp/enc_pass.tmp"
fi

# Clean up LVM snapshot if created
if [ -n "$src_snapshot" ]; then
    vg_name=$(lvs --noheadings -o vg_name "$src_snapshot" | tr -d ' ')
    remove_lvm_snapshot "$vg_name"
fi

# Send completion notification
if [ "$DRY_RUN" -eq 0 ]; then
    log "INFO" "Migration completed. Check /tmp/dd_migrate.log on the destination for details."
    send_notification "Disk Migration Complete" "Disk migration from $src_path to $dest_host:$dest_path completed successfully in ${transfer_time}s (${transfer_speed} MB/s)."
else
    log "INFO" "DRY RUN completed. No data was transferred."
fi

# Exit with success
exit 0
