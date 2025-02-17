Automated HDD Migration Tool
============================

This tool is a shell script designed for migrating hard disk data over a network. It runs on rescue systems (both Debian‑based and RHEL‑based) and performs a raw, byte-for‑byte disk clone using `dd` piped over Netcat. The script guides you through disk selection and validates that the destination disk is large enough before starting the transfer.

**Warning:** This script performs low‑level disk cloning and will irreversibly overwrite data. Use only on non‑production systems and always back up your data first.

Features
--------

*   **Automated Dependency Management:** Installs the appropriate Netcat package (netcat‑openbsd on Debian‑based systems, nmap‑ncat on RHEL‑based systems) if missing.
*   **Disk Discovery:** Lists available disks and partitions using `lsblk` and retrieves disk sizes with `blockdev`.
*   **Interactive User Prompts:** Guides you through selecting source and destination disks with built‑in size validation.
*   **Secure Remote Execution:** Connects via SSH (with optional `sshpass` support) to verify the destination disk.
*   **Data Transfer:** Uses `dd` piped through Netcat to perform a full, raw disk clone over the network.
*   **Progress Reporting:** Displays transfer status and logs key details for troubleshooting.

Requirements
------------

*   **Root Privileges:** The script must be run as root.
*   **Network Connectivity:** Ensure the chosen transfer port is open on both systems.
*   **Dependencies:**
    *   Standard utilities: `lsblk`, `dd`, `blockdev`
    *   A package manager (`apt-get` for Debian‑based systems or `yum` for RHEL‑based systems)
    *   Netcat (`netcat‑openbsd` or `nmap‑ncat`)
    *   SSH (and optionally `sshpass` for non‑interactive authentication)

Installation
------------

Download the migration script directly using either `wget` or `curl`:

### Using wget:

    wget -O migration.sh https://raw.githubusercontent.com/ENGINYRING/Automated-HDD-Migration-Tool/refs/heads/main/migration.sh
    chmod +x migration.sh

### Using curl:

    curl -o migration.sh https://raw.githubusercontent.com/ENGINYRING/Automated-HDD-Migration-Tool/refs/heads/main/migration.sh
    chmod +x migration.sh

Usage
-----

Run the script as root:

    sudo ./migration.sh

The script will perform the following steps:

1.  **Local Preparation:**
    *   Checks for and installs Netcat if missing.
    *   Lists local disk configurations and prompts you to select the source disk.
2.  **Source Disk Selection:**
    *   Prompts for the source disk (e.g., `sda`).
    *   Retrieves the source disk size using `blockdev`.
3.  **Remote Preparation:**
    *   Prompts for the destination host IP, SSH username, and (optionally) SSH password.
    *   Verifies and lists the destination disk configuration.
4.  **Destination Disk Selection & Validation:**
    *   Prompts for the destination disk.
    *   Validates that the destination disk is large enough.
5.  **Data Transfer:**
    *   Starts a Netcat listener on the destination.
    *   Pipes data from the source disk using `dd` through Netcat to the remote destination.
6.  **Completion:**
    *   Informs you when the migration is complete and logs details for review.

How It Works
------------

*   **Dependency Checks:** The script uses the local package manager to install Netcat if it is not present and remotely checks the destination system via SSH.
*   **Disk Validation:** It uses `lsblk` to display disk information and `blockdev` to compare disk sizes.
*   **Secure Data Transfer:** The script employs SSH for remote command execution (with optional `sshpass` support) and transfers data using `dd` piped through Netcat.
*   **Interactive Prompts:** User confirmations are required at key steps to prevent accidental data loss.

Disclaimer
----------

This tool is provided "as‑is" without any warranty. The authors assume no liability for any data loss or damage caused by its use. Always back up your data and test the script on non‑critical systems before using it in production.

License
-------

This project is licensed under the [MIT License](LICENSE).

Contributing
------------

Contributions are welcome. Please fork the repository, make your changes, and submit a pull request with a clear description of your improvements.

References
----------
*   [GNU Bash Manual](https://www.gnu.org/software/bash/manual/bash.html)
