# bt-mac-changer
Bluetooth MAC changer to fix dual boot bluetooth issues, by spoofing the bluetooth MAC safely.
# bt-mac-spoof

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Build Status](https://img.shields.io/badge/build-passing-brightgreen)](#)

> Safely spoof your Bluetooth MAC address on Linux using systemd. Runtime-only, non-destructive, fully automated.

---

## Features

- Persistent Bluetooth MAC spoof at boot via systemd service
- Safe: backs up original MAC before applying changes
- Flexible CLI: `--mac`, `--random`, `--interactive`, `--status`, `--restore`, `--uninstall`
- Robust: automatic tool detection (`bluemoon`, `btmgmt`, `bdaddr`)
- Idempotent & non-destructive by default

---

## Requirements

- Linux with systemd
- `hciconfig` (from `bluez`)  
- Optional: `bdaddr`, `btmgmt`, `bluemoon` (used automatically if available)

---

## Installation

Clone the repository:

```bash
git clone https://github.com/<youruser>/bt-mac-spoof.git
cd bt-mac-spoof
chmod +x install-bt-spoof.sh
sudo ./install-bt-spoof.sh --mac 50:E0:85:65:80:00
