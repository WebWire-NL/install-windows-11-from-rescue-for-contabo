
# install-windows-11-from-rescue-for-contabo

Automated script and instructions to install Windows 11 on a Contabo VPS from the rescue system, with VirtIO drivers and registry bypass for TPM, RAM, and Secure Boot checks.

## Features
- Fully automated disk partitioning and formatting
- Downloads and prepares the official Windows 11 evaluation ISO
- Integrates VirtIO drivers for disk and network support
- Adds registry and batch files to bypass Windows 11 hardware checks

## Prerequisites
- Contabo VPS (any plan)
- Access to the Contabo control panel
- VNC Viewer (e.g., RealVNC)
- SSH client (e.g., PuTTY, Terminal)

## Usage Instructions

### 1. Boot VPS into Rescue System
1. In the Contabo control panel, select your VPS and choose **Rescue System** (Debian/Ubuntu Live recommended).
2. Set a password and reboot into rescue mode.

### 2. Connect via SSH
1. SSH into your VPS using the rescue system credentials:
   ```
   ssh root@<VPS-IP>
   ```

### 3. Download and Run the Script
1. Install git if needed:
   ```
   apt install git -y
   ```
2. Clone this repository:
   ```
   git clone https://github.com/WebWire-NL/install-windows-11-from-rescue-for-contabo.git
   cd install-windows-11-from-rescue-for-contabo
   ```
3. Make the script executable and run it:
   ```
   chmod +x windows-install.sh
   ./windows-install.sh
   ```
4. The script will partition the disk, download Windows 11 and VirtIO drivers, and prepare everything. The VPS will reboot when done.

### 4. Complete Windows 11 Installation via VNC
1. In the Contabo panel, get your VNC connection info and connect with VNC Viewer.
2. Proceed with Windows 11 setup.
3. When you reach the first setup screen, press `Shift+F10` to open Command Prompt.
4. Run the following commands to bypass hardware checks:
   ```
   cd X:\sources
   bypass.cmd
   ```
5. Continue with the installation. When prompted for drivers, browse to the `virtio` folder to load storage/network drivers.

## Notes
- The script uses the official Windows 11 evaluation ISO. You can change the ISO URL in the script if needed.
- The registry and batch files are placed in the installation media's `sources` folder for easy access during setup.
- This process will erase all data on the VPS disk.

## Troubleshooting
- If you encounter issues with drivers, ensure you select the correct VirtIO drivers from the `virtio` folder during Windows setup.
- If the Windows installer does not see your disk, load the storage drivers from the same folder.

## Disclaimer
Use at your own risk. This script is provided as-is and is not affiliated with Contabo or Microsoft.
