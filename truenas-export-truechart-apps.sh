#!/bin/bash
set -euo pipefail

# CONFIGURATION
EXPORT_DIR="/root/scripts/truenas-exp-truecharts-apps/exports"
YQ_BIN="./bin/yq"
KUBECTL_BIN="k3s kubectl"
HELM_BIN="helm"

BACKUP_HOSTPATHS=false
EXPORT_K8S_RESOURCES=true
PG_DUMP_ENABLED=true
GENERATE_ONLY=${GENERATE_ONLY:-true}

PG_DUMP_NAMESPACE="default"
PG_DUMP_HOSTPATH="$EXPORT_DIR/pg_dumps"

mkdir -p "$EXPORT_DIR"
mkdir -p "$PG_DUMP_HOSTPATH"

summary_csv="$EXPORT_DIR/summary.csv"
echo "namespace,release,image,chart_version,app_version,hostpaths,service_host,docker_compose_cmd" > "$summary_csv"

# PG credentials helper
get_pg_credentials_dynamic() {
  local namespace="$1"
  local release="$2"
  local secret_user=$( \
    $KUBECTL_BIN get secrets -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | \
    grep -i 'user\|username' | grep "$release" | head -1 || true)
  [ -z "$secret_user" ] && \
    secret_user=$($KUBECTL_BIN get secrets -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'user\|username' | head -1 || true)
  local secret_pass=$( \
    $KUBECTL_BIN get secrets -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | \
    grep -i 'password\|pass' | grep "$release" | head -1 || true)
  [ -z "$secret_pass" ] && secret_pass="$secret_user"
  local user pass
  [ -n "$secret_user" ] && \
    user=$($KUBECTL_BIN get secret -n "$namespace" "$secret_user" -o jsonpath="{.data.username}" 2>/dev/null | base64 -d || true)
  [ -z "$user" ] && \
    user=$($KUBECTL_BIN get secret -n "$namespace" "$secret_user" -o jsonpath="{.data.user}" 2>/dev/null | base64 -d || true)
  [ -n "$secret_pass" ] && \
    pass=$($KUBECTL_BIN get secret -n "$namespace" "$secret_pass" -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || true)
  [ -z "$pass" ] && \
    pass=$($KUBECTL_BIN get secret -n "$namespace" "$secret_pass" -o jsonpath="{.data.pass}" 2>/dev/null | base64 -d || true)
  echo "$user:$pass"
}

# STEP 1: Export phase
apps_with_hostpath=()
apps_without_hostpath=()
apps_using_pgsql=()

if [ "$GENERATE_ONLY" != "true" ]; then
  echo "📦 Exporting all TrueCharts apps for Electric Eel migration..."
  namespaces=$($KUBECTL_BIN get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^ix-' || true)

  for ns in $namespaces; do
    echo "🔍 Checking namespace: $ns"
    releases=$($HELM_BIN list -n "$ns" -q || true)
    [ -z "$releases" ] && continue
    for release in $releases; do
      echo "📤 Exporting Helm values for: $release (namespace: $ns)"
      APP_DIR="$EXPORT_DIR/$ns/$release"
      mkdir -p "$APP_DIR"
      $HELM_BIN get values "$release" -n "$ns" -a > "$APP_DIR/original.yaml"
      $YQ_BIN eval 'del(.status, .hooks, .last_deployed, .manifest, .info)' "$APP_DIR/original.yaml" > "$APP_DIR/cleaned.yaml"

      hostpaths=$($YQ_BIN eval '.. | select(has("hostPath")) | .hostPath' "$APP_DIR/original.yaml" | grep -v 'null' || true)
      if [ -n "$hostpaths" ]; then
        apps_with_hostpath+=("$ns/$release")
        if [ "$BACKUP_HOSTPATHS" = true ]; then
          while IFS= read -r path; do
            safe_path=$(echo "$path" | sed 's|/|_|g' | sed 's|^_||')
            backup_path="$APP_DIR/hostpath_backup/$safe_path"
            mkdir -p "$backup_path"
            rsync -a "$path"/ "$backup_path"/
          done <<< "$hostpaths"
        fi
      else
        apps_without_hostpath+=("$ns/$release")
      fi

      pg_detected=$($YQ_BIN eval '.. | select(has("postgresql") or has("pgsql") or has("postgres"))' "$APP_DIR/original.yaml" || true)
      [ -n "$pg_detected" ] && apps_using_pgsql+=("$ns/$release")
    done
  done

  if [ "$EXPORT_K8S_RESOURCES" = true ]; then
    echo "📥 Exporting Services and Ingresses..."
    $KUBECTL_BIN get svc -A -o yaml > "$EXPORT_DIR/all-services.yaml"
    $KUBECTL_BIN get ingress -A -o yaml > "$EXPORT_DIR/all-ingresses.yaml"
  fi

  if [ "$PG_DUMP_ENABLED" = true ] && [ "${#apps_using_pgsql[@]}" -gt 0 ]; then
    echo "🗄️ Dumping PostgreSQL databases to: $PG_DUMP_HOSTPATH"
    for app_full in "${apps_using_pgsql[@]}"; do
      ns="${app_full%%/*}"
      release="${app_full#*/}"
      creds=$(get_pg_credentials_dynamic "$ns" "$release")
      PG_USER="${creds%%:*}"
      PG_PASSWORD="${creds#*:}"
      [ -z "$PG_USER" ] || [ -z "$PG_PASSWORD" ] && continue
      POD_NAME="psql-dump-$release"
      SERVICE_HOST="$release-cnpg-main-rw.$ns.svc.cluster.local"
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
      for db in $databases; do
        $KUBECTL_BIN exec -n $PG_DUMP_NAMESPACE $POD_NAME -- pg_dump -h "$SERVICE_HOST" -U "$PG_USER" -F c -f "/dumps/$release-$db.dump" "$db"
      done
      $KUBECTL_BIN delete pod -n $PG_DUMP_NAMESPACE $POD_NAME
    done
  fi
fi

# STEP 2: Compose file generation
echo "🔧 Generating docker-compose files..."
find "$EXPORT_DIR" -type f -name cleaned.yaml | while read -r cleaned_file; do
  ns=$(echo "$cleaned_file" | awk -F/ '{print $(NF-2)}')
  release=$(echo "$cleaned_file" | awk -F/ '{print $(NF-1)}')
  app_dir=$(dirname "$cleaned_file")
  out_compose="$app_dir/docker-compose.yaml"

  image=$($YQ_BIN e '.image.repository // ""' "$cleaned_file")
  tag=$($YQ_BIN e '.image.tag // ""' "$cleaned_file")
  chart_version=$($YQ_BIN e '.chart.version // ""' "$cleaned_file")
  app_version=$($YQ_BIN e '.appVersion // ""' "$cleaned_file")

  echo "  - Generating docker-compose for $ns/$release..."
  {
    echo "version: '3.8'"
    echo "services:"
    echo "  $release:"
    echo "    image: ${image}:${tag}"
    echo "    container_name: $release"
  } > "$out_compose"

  # --- PORTS ---
  ports_list=()
  num_ports=$($YQ_BIN e '.portForwardingList | length' "$cleaned_file" 2>/dev/null || echo 0)
  if [[ "$num_ports" -gt 0 ]]; then
    for i in $(seq 0 $((num_ports - 1))); do
      containerPort=$($YQ_BIN e ".portForwardingList[$i].containerPort" "$cleaned_file")
      nodePort=$($YQ_BIN e ".portForwardingList[$i].nodePort" "$cleaned_file")
      protocol=$($YQ_BIN e ".portForwardingList[$i].protocol" "$cleaned_file" | tr '[:upper:]' '[:lower:]')

      if [[ "$protocol" == "udp" ]]; then
        ports_list+=("\"$nodePort:$containerPort/udp\"")
      else
        ports_list+=("\"$nodePort:$containerPort\"")
      fi
    done
  else
    # fallback to main port
    port=$($YQ_BIN e '.service.main.ports.main.port // 8080' "$cleaned_file")
    target_port=$($YQ_BIN e '.service.main.ports.main.targetPort // 8080' "$cleaned_file")
    ports_list+=("\"$port:$target_port\"")
  fi

  echo "    ports:" >> "$out_compose"
  for p in "${ports_list[@]}"; do
    echo "      - $p" >> "$out_compose"
  done

  # --- VOLUMES ---
  echo "    volumes:" >> "$out_compose"

  declare -A seen=()
  hostpaths_list=()

  # 1. persistence volumes
  if [[ "$($YQ_BIN e 'has("persistence")' "$cleaned_file")" == "true" ]]; then
    mapfile -t keys < <($YQ_BIN e '.persistence | keys | .[]' "$cleaned_file" | sed 's/"//g')
    for key in "${keys[@]}"; do
      enabled=$($YQ_BIN e ".persistence.\"$key\".enabled // false" "$cleaned_file")
      hostPath=$($YQ_BIN e ".persistence.\"$key\".hostPath // \"\"" "$cleaned_file")
      mountPath=$($YQ_BIN e ".persistence.\"$key\".mountPath // \"\"" "$cleaned_file")
      if [[ "$enabled" == "true" && -n "$hostPath" && "$hostPath" != "null" && "$mountPath" != "null" && -z "${seen[$hostPath]+x}" ]]; then
        echo "      - \"$hostPath:$mountPath\"" >> "$out_compose"
        seen[$hostPath]=1
        hostpaths_list+=("$hostPath")
      fi
    done
  fi

  # 2. hostPathVolumes array
  num_hostpath_volumes=$($YQ_BIN e '.hostPathVolumes | length' "$cleaned_file" 2>/dev/null || echo 0)
  if [[ "$num_hostpath_volumes" -gt 0 ]]; then
    for i in $(seq 0 $((num_hostpath_volumes - 1))); do
      hostPath=$($YQ_BIN e ".hostPathVolumes[$i].hostPath // \"\"" "$cleaned_file")
      mountPath=$($YQ_BIN e ".hostPathVolumes[$i].mountPath // \"\"" "$cleaned_file")
      if [[ -n "$hostPath" && "$hostPath" != "null" && "$mountPath" != "null" && -z "${seen[$hostPath]+x}" ]]; then
        echo "      - \"$hostPath:$mountPath\"" >> "$out_compose"
        seen[$hostPath]=1
        hostpaths_list+=("$hostPath")
      fi
    done
  fi

  # 3. any other hostPaths anywhere else in YAML
  mapfile -t all_hostpaths < <($YQ_BIN e '.. | select(has("hostPath")) | .hostPath' "$cleaned_file" | grep -v 'null' || true)
  for path in "${all_hostpaths[@]}"; do
    path_trimmed=$(echo "$path" | xargs)
    if [[ -n "$path_trimmed" && -z "${seen[$path_trimmed]+x}" ]]; then
      echo "      - \"$path_trimmed:$path_trimmed\"" >> "$out_compose"
      seen[$path_trimmed]=1
      hostpaths_list+=("$path_trimmed")
    fi
  done

  echo "    restart: unless-stopped" >> "$out_compose"

  service_host="$release-cnpg-main-rw.$ns.svc.cluster.local"
  docker_compose_cmd="cd $app_dir && docker compose up -d"

  hostpaths_str=$(IFS=';' ; echo "${hostpaths_list[*]}")
  echo "$ns,$release,\"${image}:${tag}\",$chart_version,$app_version,\"$hostpaths_str\",$service_host,\"$docker_compose_cmd\"" >> "$summary_csv"
done

echo "✅ Done. Summary written to: $summary_csv"
echo
echo "📊 Docker Compose Migration Summary"
echo "==================================="
column -s ',' -t < "$summary_csv" | less -FXSR

