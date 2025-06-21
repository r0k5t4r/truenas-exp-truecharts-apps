#!/bin/bash
set -euo pipefail

# Konfiguration

EXPORT_DIR="/root/scripts/truenas-exp-truecharts-apps/exports"
YQ_BIN="./bin/yq"       # yq muss ausführbar sein
KUBECTL_BIN="k3s kubectl"
HELM_BIN="helm"

BACKUP_HOSTPATHS=false  # true um hostPath Daten zu sichern (Backup)
EXPORT_K8S_RESOURCES=true
PG_DUMP_ENABLED=true

# Namespace und Pfad für PostgreSQL Dump-Pod
PG_DUMP_NAMESPACE="default"
PG_DUMP_HOSTPATH="$EXPORT_DIR/pg_dumps"

mkdir -p "$EXPORT_DIR"
mkdir -p "$PG_DUMP_HOSTPATH"

apps_with_hostpath=()
apps_without_hostpath=()
apps_using_pgsql=()

echo "📦 Exporting all TrueCharts apps for Electric Eel migration..."

# Hilfsfunktion: dynamische Suche nach PG Credentials in Secrets
get_pg_credentials_dynamic() {
  local namespace="$1"
  local release="$2"

  local secret_user=$( \
    $KUBECTL_BIN get secrets -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | \
    grep -i 'user\|username' | grep "$release" | head -1 || true)

  if [ -z "$secret_user" ]; then
    secret_user=$($KUBECTL_BIN get secrets -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'user\|username' | head -1 || true)
  fi

  local secret_pass=$( \
    $KUBECTL_BIN get secrets -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | \
    grep -i 'password\|pass' | grep "$release" | head -1 || true)

  if [ -z "$secret_pass" ]; then
    secret_pass=$($KUBECTL_BIN get secrets -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'password\|pass' | head -1 || true)
  fi

  if [ "$secret_pass" == "" ]; then
    secret_pass="$secret_user"
  fi

  local user=""
  local pass=""

  if [ -n "$secret_user" ]; then
    user=$($KUBECTL_BIN get secret -n "$namespace" "$secret_user" -o jsonpath="{.data.username}" 2>/dev/null | base64 -d || echo "")
    if [ -z "$user" ]; then
      user=$($KUBECTL_BIN get secret -n "$namespace" "$secret_user" -o jsonpath="{.data.user}" 2>/dev/null | base64 -d || echo "")
    fi
  fi

  if [ -n "$secret_pass" ]; then
    pass=$($KUBECTL_BIN get secret -n "$namespace" "$secret_pass" -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
    if [ -z "$pass" ]; then
      pass=$($KUBECTL_BIN get secret -n "$namespace" "$secret_pass" -o jsonpath="{.data.pass}" 2>/dev/null | base64 -d || echo "")
    fi
  fi

  echo "$user:$pass"
}

# Alle Namespaces mit Prefix ix- holen
namespaces=$($KUBECTL_BIN get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^ix-' || true)

for ns in $namespaces; do
  echo "🔍 Checking namespace: $ns"

  # Releases im Namespace
  releases=$($HELM_BIN list -n "$ns" -q || true)
  if [ -z "$releases" ]; then
    echo "⚠️ No Helm releases found in namespace $ns"
    echo "------------------------------"
    continue
  fi

  for release in $releases; do
    echo "📤 Exporting Helm values for: $release (namespace: $ns)"
    APP_DIR="$EXPORT_DIR/$ns/$release"
    mkdir -p "$APP_DIR"

    $HELM_BIN get values "$release" -n "$ns" -a > "$APP_DIR/original.yaml"
    $YQ_BIN eval 'del(.status, .hooks, .last_deployed, .manifest, .info)' "$APP_DIR/original.yaml" > "$APP_DIR/cleaned.yaml"
    echo "✅ Cleaned values saved to: $APP_DIR/cleaned.yaml"

    hostpaths=$($YQ_BIN eval '.. | select(has("hostPath")) | .hostPath' "$APP_DIR/original.yaml" | grep -v 'null' || true)

    if [ -n "$hostpaths" ]; then
      echo "⚠️ Found hostPath volumes in $release:"
      echo "$hostpaths"
      apps_with_hostpath+=("$ns/$release")

      if [ "$BACKUP_HOSTPATHS" = true ]; then
        echo "⏳ Backing up hostPath volumes for $release ..."
        while IFS= read -r path; do
          safe_path=$(echo "$path" | sed 's|/|_|g' | sed 's|^_||')
          backup_path="$APP_DIR/hostpath_backup/$safe_path"
          mkdir -p "$backup_path"
          echo "Backing up $path to $backup_path ..."
          rsync -a "$path"/ "$backup_path"/
        done <<< "$hostpaths"
      else
        echo "⚠️ Backup of hostPath volumes skipped by user setting."
      fi
    else
      echo "✅ No hostPath volumes found in $release"
      apps_without_hostpath+=("$ns/$release")
    fi

    echo "📦 PVCs in $ns/$release:"
    PVC_LIST=$($KUBECTL_BIN get pvc -n "$ns" -l "app.kubernetes.io/instance=$release" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,CAPACITY:.spec.resources.requests.storage,ACCESS_MODES:.spec.accessModes,STORAGECLASS:.spec.storageClassName --no-headers || true)
    if [ -z "$PVC_LIST" ]; then
      echo "No resources found in $ns namespace."
    else
      echo "$PVC_LIST"
    fi
    echo "------------------------------"

    # PostgreSQL-Erkennung über Schlüssel in original.yaml
    pg_detected=$($YQ_BIN eval '.. | select(has("postgresql") or has("pgsql") or has("postgres"))' "$APP_DIR/original.yaml" || true)
    if [ -n "$pg_detected" ]; then
      apps_using_pgsql+=("$ns/$release")
    fi

  done
done

echo -e "\n📋 Migration Summary:"
echo "-----------------------------------"
echo "Apps WITH hostPath volumes:"
for app in "${apps_with_hostpath[@]}"; do echo "  - $app"; done

echo "Apps WITHOUT hostPath volumes:"
for app in "${apps_without_hostpath[@]}"; do echo "  - $app"; done
echo "-----------------------------------"

if [ "$EXPORT_K8S_RESOURCES" = true ]; then
  echo "📥 Exporting all Services and Ingresses to $EXPORT_DIR"
  $KUBECTL_BIN get svc -A -o yaml > "$EXPORT_DIR/all-services.yaml"
  $KUBECTL_BIN get ingress -A -o yaml > "$EXPORT_DIR/all-ingresses.yaml"
fi

if [ "$PG_DUMP_ENABLED" = true ] && [ "${#apps_using_pgsql[@]}" -gt 0 ]; then
  echo "🗄️ PostgreSQL usage detected in charts:"
  for app in "${apps_using_pgsql[@]}"; do echo "  - $app"; done

  echo "🗄️ Dumping PostgreSQL databases to host path: $PG_DUMP_HOSTPATH ..."

  for app_full in "${apps_using_pgsql[@]}"; do
    ns="${app_full%%/*}"
    release="${app_full#*/}"

    echo "🔍 Processing PostgreSQL dump for $app_full..."

    creds=$(get_pg_credentials_dynamic "$ns" "$release")
    PG_USER="${creds%%:*}"
    PG_PASSWORD="${creds#*:}"

    if [ -z "$PG_USER" ] || [ -z "$PG_PASSWORD" ]; then
      echo "⚠️ Could not find PostgreSQL credentials for $app_full, skipping dump."
      continue
    fi

    echo "✅ Found credentials for user $PG_USER."

    POD_NAME="psql-dump-$release"
    SERVICE_HOST="$release-cnpg-main-rw.$ns.svc.cluster.local"

    echo "🛠️ Creating dump pod $POD_NAME in $PG_DUMP_NAMESPACE..."

    cat <<EOF | $KUBECTL_BIN apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $PG_DUMP_NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: psql-client
    image: postgres:16
    command: ["sleep", "3600"]
    env:
    - name: PGPASSWORD
      value: "$PG_PASSWORD"
    volumeMounts:
    - mountPath: /dumps
      name: pgdump
  volumes:
  - name: pgdump
    hostPath:
      path: $PG_DUMP_HOSTPATH
      type: DirectoryOrCreate
EOF

    $KUBECTL_BIN wait pod/$POD_NAME -n $PG_DUMP_NAMESPACE --for=condition=Ready --timeout=60s

    databases=$($KUBECTL_BIN exec -n $PG_DUMP_NAMESPACE $POD_NAME -- psql -h "$SERVICE_HOST" -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | tr -d ' ' | grep -v '^$')
    echo "Databases found: $databases"

    for db in $databases; do
      echo "Dumping database: $db"
      $KUBECTL_BIN exec -n $PG_DUMP_NAMESPACE $POD_NAME -- pg_dump -h "$SERVICE_HOST" -U "$PG_USER" -F c -f "/dumps/$release-$db.dump" "$db"
    done

    $KUBECTL_BIN delete pod -n $PG_DUMP_NAMESPACE $POD_NAME
  done

  echo "🗄️ PostgreSQL dumps stored on host at: $PG_DUMP_HOSTPATH"
fi

echo "🎉 All TrueCharts apps exported and cleaned."

exit 0

