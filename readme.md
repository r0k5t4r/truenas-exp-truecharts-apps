
# TrueNAS TrueCharts App Export Script

This script helps you export and migrate TrueCharts Kubernetes apps from TrueNAS SCALE (pre-Electric Eel) to a Docker Compose setup.

It:

- Extracts **Helm values** from all installed apps (from previous k3s deployment).
- Generates cleaned `docker-compose.yaml` files.
- Detects and includes:
  - Host paths from `.persistence.*`
  - Volumes defined in `hostPathVolumes[]`
  - Any additional `.hostPath` keys found in the YAML
- Optionally:
  - Dumps PostgreSQL databases using temporary pods
  - Exports Kubernetes service and ingress resources
- Outputs a formatted `summary.csv` showing all exported apps.

---

## 🔧 Features

- Supports legacy TrueNAS SCALE (before Electric Eel)
- Migrates apps to portable Docker Compose format
- Detects **host paths from all relevant YAML locations**
- Optional PostgreSQL database backup via `pg_dump`
- Optional rsync backup of hostPath volumes

---

## 🧰 Requirements

- `yq` (binary included or installable)
- `helm`, `kubectl` (for legacy k3s access)
- `bash`, `rsync`, `base64`, `awk`, `sed`, `grep`
- A working `/mnt` volume for exported data

---

## 🚀 Usage

```bash
chmod +x truenas-export-truechart-apps.sh
./truenas-export-truechart-apps.sh
```

The script will:

1. Loop through all `ix-*` namespaces and Helm releases
2. Export `original.yaml` and `cleaned.yaml`
3. Generate `docker-compose.yaml` files in per-app folders
4. Write a `summary.csv` listing:
   - Namespace, release, image, chart version, app version
   - All detected hostPaths
   - Compose startup command
   - Optional service hostname (for PG)

---

## 📁 Output Directory Structure

```
exports/
├── ix-appname/
│   └── release-name/
│       ├── original.yaml
│       ├── cleaned.yaml
│       ├── docker-compose.yaml
│       └── hostpath_backup/   (if enabled)
├── all-services.yaml          (if enabled)
├── all-ingresses.yaml         (if enabled)
├── summary.csv
└── pg_dumps/                  (if PG export enabled)
```

---

## 📦 Example summary.csv

| Namespace     | Release     | Image                        | Chart Version | App Version | HostPaths                                     | Compose Command                      |
|---------------|-------------|------------------------------|----------------|--------------|-----------------------------------------------|--------------------------------------|
| ix-teamspeak3 | teamspeak3  | teamspeak:latest             | 10.2.0         | 3.13.7       | /mnt/zpool0/k8s/teamspeak3/config;/data       | `cd exports/ix-teamspeak3/teamspeak3 && docker compose up -d` |

---

## 📝 Notes

- You must run this **before upgrading to Electric Eel**, as it relies on access to `k3s`, Helm, and old TrueCharts layout.
- PostgreSQL dumps require network access and credentials auto-detected from Kubernetes secrets.
- App versions may not always be resolvable if Helm metadata is no longer accessible.

---

## 📸 Blogpost

This script and the migration process are also documented in [my blog post](https://www.roksblog.de/) (to be published soon).

---

## 💡 License

MIT — use freely, contributions welcome!

