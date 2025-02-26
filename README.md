# Enhanced Automated HDD Migration Tool

This tool is a powerful shell script designed for migrating hard disk data over a network. It runs on the **source** server (from which you want to copy data) and transfers disk data to a remote destination server. Compatible with rescue systems (both Debian‑based and RHEL‑based), it performs a raw, byte-for‑byte disk clone with numerous options for safety, speed, and security. The script guides you through disk selection and validates that the destination disk is large enough before starting the transfer.

**Warning:** This script performs low‑level disk cloning and will irreversibly overwrite data. Use only on non‑production systems and always back up your data first.

## Features

### Core Functionality
* **Automated Dependency Management:** Installs required packages (netcat, compression tools, etc.) if missing
* **Disk Discovery:** Lists available disks and partitions using `lsblk` and retrieves disk sizes with `blockdev`
* **Interactive User Prompts:** Guides you through selecting source and destination disks with built‑in size validation
* **Secure Remote Execution:** Connects via SSH to verify and prepare the destination disk
* **Data Transfer:** Uses `dd` piped through Netcat to perform a full, raw disk clone over the network
* **Progress Reporting:** Displays transfer status and logs key details for troubleshooting

### Enhanced Safety Features
* **Metadata Backup:** Automatically creates backups of MBR/partition tables before overwriting
* **Mounted Filesystem Detection:** Warns and offers safety options when disks are mounted
* **LVM Snapshot Support:** For safely migrating live systems without downtime
* **Transfer Validation:** Optional checksum verification of transferred data
* **Structured Logging:** Comprehensive timestamped logs with different severity levels
* **Resume Capability:** Can continue interrupted transfers without starting over

### Performance Enhancements
* **Configurable Block Size:** Tune performance based on network and disk characteristics
* **Compression:** Optional on-the-fly compression to speed up transfers over slow links
* **Bandwidth Throttling:** Optional bandwidth limiting to prevent network saturation
* **Progress Monitoring:** Real-time transfer status with speed and time calculations

### Security Features
* **Transfer Encryption:** Optional AES-256 encryption for sensitive data
* **SSH Security Options:** Configurable timeouts and connection settings
* **Secure Password Handling:** Better management of SSH credentials

### Usability Improvements
* **Command-Line Interface:** Scriptable with full command-line options
* **Configuration Files:** Store common settings in config files
* **Dry Run Mode:** Preview operations without making changes
* **Notification System:** Optional email alerts on completion or failure
* **Non-Interactive Mode:** Run without prompts for scripting and automation

## Requirements

* **Root Privileges:** The script must be run as root
* **Network Connectivity:** Ensure the chosen transfer port is open on both systems
* **Dependencies:**
    * Standard utilities: `lsblk`, `dd`, `blockdev`
    * A package manager (`apt-get`, `yum`, or `dnf`)
    * SSH (and optionally `sshpass` for non‑interactive authentication)
    * Optional: `pv`, `gzip`, `openssl`, `mail` (for advanced features)

## Installation

Download the migration script directly using either `wget` or `curl`:

```bash
# Using wget
wget -O disk-migration.sh https://raw.githubusercontent.com/ENGINYRING/Automated-HDD-Migration-Tool/refs/heads/main/disk-migration.sh
chmod +x disk-migration.sh

# Using curl
curl -o disk-migration.sh https://raw.githubusercontent.com/ENGINYRING/Automated-HDD-Migration-Tool/refs/heads/main/disk-migration.sh
chmod +x disk-migration.sh
```

## Usage

### Basic Usage

Run the script with no arguments for interactive mode:

```bash
sudo ./disk-migration.sh
```

### Command-Line Arguments

For scripting or automation, use command-line arguments:

```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin
```

### Using Advanced Features

#### With Data Validation
```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin --validate
```

#### With Compression (for slow networks)
```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin --compress
```

#### For Live Systems (using LVM)
```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin --snapshot
```

#### With Transfer Encryption
```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin --encrypt
```

#### Limiting Bandwidth
```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin -l 10M
```

#### Resuming an Interrupted Transfer
```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin --continue
```

> **Note**: Always run this command on the same source server where the original transfer was initiated.

### Complete Options List

```
Usage: ./disk-migration.sh [OPTIONS]

Disk Migration Tool - Safely clone disks over SSH

OPTIONS:
  -h, --help                Show this help message
  -c, --config FILE         Use specific config file
  -s, --source DISK         Source disk (e.g., sda)
  -d, --dest DISK           Destination disk
  -H, --host HOST           Destination host
  -u, --user USER           SSH username
  -p, --port PORT           SSH port (default: 22)
  -t, --transfer-port PORT  Data transfer port (default: 9000)
  -b, --block-size SIZE     Block size for dd (default: 64K)
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
```

## Configuration Files

The script can load settings from configuration files:

```bash
# Use default configuration
sudo ./disk-migration.sh

# Use specific configuration file
sudo ./disk-migration.sh -c /path/to/my-config.conf
```

A default configuration file is created in `$HOME/.config/disk-migration/config.conf` the first time you run the script. You can customize this file with your preferred settings.

### Example Configuration File

```bash
# Disk Migration Tool Configuration

# Transfer Settings
BLOCK_SIZE="64K"      # Block size for dd
DEFAULT_PORT=9000     # Default netcat port
COMPRESSION=0         # Enable compression (0=off, 1=on)
VALIDATE=0            # Validate transfer with checksums
ENCRYPT_TRANSFER=0    # Encrypt data during transfer
#BANDWIDTH_LIMIT="10M" # Limit bandwidth (e.g., 10M, 1G)

# SSH Settings
dest_host="server.example.com"  # Destination host
dest_user="admin"               # SSH username
ssh_port="22"                   # SSH port

# LVM Settings
USE_LVM_SNAPSHOT=0    # Use LVM snapshot for live migration
SNAPSHOT_NAME="disk_migration_snapshot"

# Notification Settings
NOTIFICATION_EMAIL="admin@example.com"  # Email for notifications
```

## Where to Run the Script

This script must be run on the **source** server (the machine containing the disk you want to clone). It will:
1. Read data from your local disk
2. Connect via SSH to the destination server 
3. Set up a netcat listener on the destination
4. Transfer the disk data over the network

The destination server only needs SSH access and appropriate tools (which the script will install if missing).

## How the Transfer Works

1. **Preparation Phase**
   - Checks for required tools on both source and destination machines
   - Validates disks exist and destination has sufficient space
   - Creates MBR/partition table backups
   - Sets up LVM snapshots if needed for live systems

2. **Transfer Phase**
   - Creates optimized transfer pipeline based on selected options
   - Starts netcat listener on destination
   - Transfers data with dd through the pipeline
   - Monitors progress and creates checkpoints for resume capability

3. **Verification Phase (Optional)**
   - Performs sampling-based checksums on source and destination
   - Compares checksums to verify data integrity
   - Reports validation results and sends notifications

4. **Cleanup Phase**
   - Removes temporary files and snapshots
   - Logs completion details and transfer statistics

## Logging

The script creates detailed logs in `/var/log/disk-migration-YYYYMMDD-HHMMSS.log` with all operations, warnings, and errors. These logs are invaluable for troubleshooting failed transfers or verifying successful ones.

## Resuming Interrupted Transfers

One of the most powerful features of this tool is the ability to resume interrupted transfers, which is especially valuable when migrating large disks over unreliable networks.

### How Resume Works

1. **Automatic State Tracking**:
   - During transfer, the script periodically saves transfer progress to a state file
   - This file tracks source/destination disks, hostname, and exact byte offset
   - The state is saved in `$HOME/.config/disk-migration/transfer_state.json`

2. **Resuming Process**:
   - When you use the `--continue` flag, the script loads the saved state
   - Verifies that current parameters match the saved transfer
   - Uses `dd`'s `skip` and `seek` parameters to start from the saved position
   - Only transfers the remaining data, saving potentially hours or days

3. **Example Scenario**:
   - You're transferring a 4TB disk and after 2TB, your network connection drops
   - Simply run the same command with `--continue` added
   - The transfer resumes from approximately the 2TB mark

### Manual Offset

If you need to specify a particular starting point manually:

```bash
sudo ./disk-migration.sh -s sda -d sdb -H remote.host -u admin --offset 1073741824
```

This starts the transfer from the 1GB mark. This can be useful if you know exactly where a transfer failed or if you want to skip certain portions of the disk.

## Advanced Use Cases

### Scheduled Migrations

Use cron to schedule regular migrations:

```bash
# Example cron entry for daily migration at 2 AM
0 2 * * * /path/to/disk-migration.sh -c /path/to/config.conf > /var/log/scheduled-migration.log 2>&1
```

### Creating Disk Images

To create a disk image file instead of directly cloning to another disk:

```bash
# On the destination machine, create a file of appropriate size
dd if=/dev/zero of=/path/to/disk.img bs=1M count=<size_in_MB>

# Set up a loop device on the destination
losetup /dev/loop0 /path/to/disk.img

# Then use the script with loop0 as destination
./disk-migration.sh -s sda -d loop0 -H destination-host -u admin
```

### Pre/Post Migration Scripts

For complex migrations, create wrapper scripts that run preparation or finalization tasks:

```bash
#!/bin/bash
# Pre-migration tasks
umount /dev/sda1  # Unmount filesystems
systemctl stop some-service  # Stop services

# Run migration
./disk-migration.sh -s sda -d sdb -H remote.host -u admin

# Post-migration tasks
ssh user@remote.host "mount /dev/sdb1 /mnt && chroot /mnt grub-install /dev/sdb"
```

## Disclaimer

This tool is provided "as‑is" without any warranty. The authors assume no liability for any data loss or damage caused by its use. Always back up your data and test the script on non‑critical systems before using it in production.

## License

This project is licensed under the [MIT License](LICENSE).

## Contributing

Contributions are welcome. Please fork the repository, make your changes, and submit a pull request with a clear description of your improvements.
