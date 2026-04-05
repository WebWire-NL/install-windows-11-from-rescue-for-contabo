# Install Windows 11 from Rescue on Contabo VPS

This project provides an automated script and instructions to install Windows 11 on a Contabo VPS using the rescue system, with VirtIO drivers and registry bypass for TPM, RAM, and Secure Boot checks.

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
- In the Contabo control panel, select your VPS and choose "Rescue System" (Debian/Ubuntu Live recommended).
- Set a password and reboot into rescue mode.

### 2. Connect via SSH
- SSH into your VPS using the rescue system credentials:
  ```
  ssh root@<VPS-IP>
  ```

### 3. Download and Run the Script
- Install git if needed:
  ```
  apt install git -y
  ```
- Clone this repository:
  ```
  git clone <your-repo-url>
  cd install-windows11-from-rescue-contabo-vps
  ```
- Make the script executable and run it:
  ```
  chmod +x windows-install.sh
  ./windows-install.sh
  ```
- The script will partition the disk, download Windows 11 and VirtIO drivers, and prepare everything. The VPS will reboot when done.

### 4. Complete Windows 11 Installation via VNC
- In the Contabo panel, get your VNC connection info and connect with VNC Viewer.
- Proceed with Windows 11 setup.
- When you reach the first setup screen, press `Shift+F10` to open Command Prompt.
- Run the following commands to bypass hardware checks:
  ```
  cd X:\sources
  bypass.cmd
  ```
- Continue with the installation. When prompted for drivers, browse to the `virtio` folder to load storage/network drivers.

## Notes
- The script uses the official Windows 11 evaluation ISO. You can change the ISO URL in the script if needed.
- The registry and batch files are placed in the installation media's `sources` folder for easy access during setup.
- This process will erase all data on the VPS disk.

## Disclaimer
Use at your own risk. This script is provided as-is and is not affiliated with Contabo or Microsoft.
