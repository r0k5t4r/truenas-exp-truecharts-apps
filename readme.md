# TrueNAS SCALE TrueCharts App Migration Helper

This script helps you export and re-deploy your TrueCharts apps on TrueNAS SCALE—ideal for system upgrades or clean re-installs.  
Originally created during my upgrade from **24.04 "Dragonfish"** to **24.10 "Electric Eel"**, it greatly reduced the manual steps required for app migration.

## 🧩 What it does

- Detects installed TrueCharts apps
- Exports app configuration and associated secrets
- Creates re-deployable manifests
- Optional: cleans up old or broken apps
- Saves everything into a single `exports/` directory

## 📦 Requirements

- `k3s kubectl` or a working `kubectl` alias
- Access to the TrueNAS SCALE CLI
- Python 3 for the helper scripts

## 💻 Usage

Clone the repo and run the main script:

```bash
git clone https://github.com/r0k5t4r/truenas-exp-truecharts-apps.git
cd truenas-exp-truecharts-apps
./export_apps.sh

