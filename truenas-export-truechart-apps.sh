#!/bin/bash
set -euo pipefail

# CONFIGURATION
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
EXPORT_DIR="/root/scripts/truenas-exp-truecharts-apps/exports"
YQ_BIN="./bin/yq"
KUBECTL_BIN="k3s kubectl"
HELM_BIN="helm"

BACKUP_HOSTPATHS=false
EXPORT_K8S_RESOURCES=true
PG_DUMP_ENABLED=true
GENERATE_ONLY=${GENERATE_ONLY:-false}

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

  # --- COMMAND ---
  container_command=$($YQ_BIN e '.containerCommand // []' "$cleaned_file" | grep -v 'null' | grep -v '\[\]' || true)
  if [[ -n "$container_command" ]]; then
    $YQ_BIN e '.containerCommand[]' "$cleaned_file" | while read -r cmd; do
      echo "    entrypoint: \"$cmd\"" >> "$out_compose"
    done
  fi

  # --- ARGS ---
  container_args=$($YQ_BIN e '.containerArgs // []' "$cleaned_file" | grep -v 'null' | grep -v '\[\]' || true)
  if [[ -n "$container_args" ]]; then
    echo "    command:" >> "$out_compose"
    $YQ_BIN e '.containerArgs[]' "$cleaned_file" | while read -r arg; do
      echo "      - \"$arg\"" >> "$out_compose"
    done
  fi

  # --- ENVIRONMENT VARIABLES ---
  num_envs=$($YQ_BIN e '.containerEnvironmentVariables | length' "$cleaned_file" 2>/dev/null || echo 0)
  if [[ "$num_envs" -gt 0 ]]; then
    echo "    environment:" >> "$out_compose"
    for i in $(seq 0 $((num_envs - 1))); do
      env_name=$($YQ_BIN e ".containerEnvironmentVariables[$i].name" "$cleaned_file")
      env_value=$($YQ_BIN e ".containerEnvironmentVariables[$i].value" "$cleaned_file")
      if [[ -n "$env_name" && "$env_name" != "null" ]]; then
        echo "      - $env_name=$env_value" >> "$out_compose"
      fi
    done
  fi

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

  # --- emptyDirVolumes ---
  num_emptydir_volumes=$($YQ_BIN e '.emptyDirVolumes | length' "$cleaned_file" 2>/dev/null || echo 0)
  if [[ "$num_emptydir_volumes" -gt 0 ]]; then
    for i in $(seq 0 $((num_emptydir_volumes - 1))); do
      mountPath=$($YQ_BIN e ".emptyDirVolumes[$i].mountPath // \"\"" "$cleaned_file")
      if [[ -n "$mountPath" && "$mountPath" != "null" && -z "${seen[$mountPath]+x}" ]]; then
        # For emptyDir, use tmpfs for ephemeral storage
        sizeLimit=$($YQ_BIN e ".emptyDirVolumes[$i].sizeLimit // \"\"" "$cleaned_file")
        echo "      - type: tmpfs" >> "$out_compose"
        echo "        target: $mountPath" >> "$out_compose"
        if [[ -n "$sizeLimit" && "$sizeLimit" != "null" ]]; then
          # Convert sizeLimit to docker-compose format (e.g., 1Gi -> 1g, 512Mi -> 512m)
          if [[ "$sizeLimit" =~ ^([0-9]+)Gi$ ]]; then
            size_val="${BASH_REMATCH[1]}"
            sizeLimit="${size_val}g"
          elif [[ "$sizeLimit" =~ ^([0-9]+)Mi$ ]]; then
            size_val="${BASH_REMATCH[1]}"
            sizeLimit="${size_val}m"
          fi
          echo "        tmpfs:" >> "$out_compose"
          echo "          size: $sizeLimit" >> "$out_compose"
        fi
        seen[$mountPath]=1
      fi
    done
  fi

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
      readOnly=$($YQ_BIN e ".hostPathVolumes[$i].readOnly // false" "$cleaned_file")
      if [[ -n "$hostPath" && "$hostPath" != "null" && "$mountPath" != "null" && -z "${seen[$hostPath]+x}" ]]; then
        if [[ "$readOnly" == "true" ]]; then
          echo "      - \"$hostPath:$mountPath:ro\"" >> "$out_compose"
        else
          echo "      - \"$hostPath:$mountPath\"" >> "$out_compose"
        fi
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

  # --- CPUS ---
  cpu_limit=$($YQ_BIN e '.resources.limits.cpu // .cpuLimit // "0"' "$cleaned_file")
  # Normalize cpu_limit (e.g., "500m" -> "0.5")
  if [[ "$cpu_limit" =~ ^[0-9]+m$ ]]; then
    cpu_val=$(echo "$cpu_limit" | sed 's/m$//')
    cpu_limit=$(awk "BEGIN {printf \"%.3f\", $cpu_val/1000}")
  fi
  echo "    cpus: $cpu_limit" >> "$out_compose"

  # --- MEMORY ---
  mem_limit=$($YQ_BIN e '.resources.limits.memory // .memLimit // "0"' "$cleaned_file")
  # Normalize mem_limit (e.g., "512Mi" -> "512m", "2Gi" -> "2048m")
  if [[ "$mem_limit" =~ ^([0-9]+)Mi$ ]]; then
    mem_val="${BASH_REMATCH[1]}"
    mem_limit="${mem_val}m"
  elif [[ "$mem_limit" =~ ^([0-9]+)Gi$ ]]; then
    mem_val="${BASH_REMATCH[1]}"
    mem_limit="${mem_val}g"
  fi
  echo "    mem_limit: $mem_limit" >> "$out_compose"

  # --- GPU SUPPORT ---
  if [[ "$($YQ_BIN e 'has("gpuConfiguration")' "$cleaned_file")" == "true" ]]; then
    mapfile -t gpu_keys < <($YQ_BIN e '.gpuConfiguration | keys | .[]' "$cleaned_file" | sed 's/"//g')
    for gpu_key in "${gpu_keys[@]}"; do
      gpu_count=$($YQ_BIN e ".gpuConfiguration.\"$gpu_key\"" "$cleaned_file")
      if [[ "$gpu_count" != "null" && "$gpu_count" -gt 0 ]]; then
        case "$gpu_key" in
          nvidia.com/gpu)
            echo "    deploy:" >> "$out_compose"
            echo "      resources:" >> "$out_compose"
            echo "        reservations:" >> "$out_compose"
            echo "          devices:" >> "$out_compose"
            echo "            - driver: nvidia" >> "$out_compose"
            echo "              count: $gpu_count" >> "$out_compose"
            echo "              capabilities: [gpu]" >> "$out_compose"
            ;;
          amd.com/gpu)
            echo "    # AMD GPU requested: $gpu_count (manual configuration may be required)" >> "$out_compose"
            ;;
          gpu.intel.com/i915)
            echo "    # Intel GPU requested: $gpu_count (manual configuration may be required)" >> "$out_compose"
            ;;
          *)
            echo "    # Unknown GPU key: $gpu_key count: $gpu_count" >> "$out_compose"
            ;;
        esac
      fi
    done
  fi

  # --- SECURITY CONTEXT ---
  if [[ "$($YQ_BIN e 'has("securityContext")' "$cleaned_file")" == "true" ]]; then
    runAsUser=$($YQ_BIN e '.securityContext.runAsUser // ""' "$cleaned_file")
    runAsGroup=$($YQ_BIN e '.securityContext.runAsGroup // ""' "$cleaned_file")
    privileged=$($YQ_BIN e '.securityContext.privileged // false' "$cleaned_file")
    capabilities=$($YQ_BIN e '.securityContext.capabilities // []' "$cleaned_file")
    enableRunAsUser=$($YQ_BIN e '.securityContext.enableRunAsUser // false' "$cleaned_file")

    # Add user/group if set
    if [[ -n "$runAsUser" && "$runAsUser" != "null" ]]; then
      echo "    user: \"$runAsUser:$runAsGroup\"" >> "$out_compose"
      
    fi
    # Add privileged if true
    if [[ "$privileged" == "true" ]]; then
      echo "    privileged: true" >> "$out_compose"
    fi

    # Add capabilities if not empty
    cap_count=$($YQ_BIN e '.securityContext.capabilities | length' "$cleaned_file" 2>/dev/null || echo 0)
    if [[ "$cap_count" -gt 0 ]]; then
      echo "    cap_add:" >> "$out_compose"
      for ((k=0; k<cap_count; k++)); do
        cap=$($YQ_BIN e ".securityContext.capabilities[$k]" "$cleaned_file")
        if [[ -n "$cap" && "$cap" != "null" ]]; then
          echo "      - $cap" >> "$out_compose"
        fi
      done
    fi
  fi

  # --- STDIN/TTY ---
  stdin=$($YQ_BIN e '.stdin // false' "$cleaned_file")
  tty=$($YQ_BIN e '.tty // false' "$cleaned_file")
  if [[ "$stdin" == "true" ]]; then
    echo "    stdin_open: true" >> "$out_compose"
  fi
  if [[ "$tty" == "true" ]]; then
    echo "    tty: true" >> "$out_compose"
  fi

  echo "    restart: unless-stopped" >> "$out_compose"

  # --- NETWORKS ---
  echo "    networks:" >> "$out_compose"
  echo "      ix-apps:" >> "$out_compose"
  echo "        aliases:" >> "$out_compose"
  echo "          - $release.$ns.svc.cluster.local" >> "$out_compose"

  # --- EXTERNAL INTERFACES (static IPs) ---
  num_ext_ifaces=$($YQ_BIN e '.externalInterfaces | length' "$cleaned_file" 2>/dev/null || echo 0)
  if [[ "$num_ext_ifaces" -gt 0 ]]; then
    for i in $(seq 0 $((num_ext_ifaces - 1))); do
      num_static_ips=$($YQ_BIN e ".externalInterfaces[$i].ipam.staticIPConfigurations | length" "$cleaned_file" 2>/dev/null || echo 0)
      if [[ "$num_static_ips" -gt 0 ]]; then
        for j in $(seq 0 $((num_static_ips - 1))); do
          static_ip=$($YQ_BIN e ".externalInterfaces[$i].ipam.staticIPConfigurations[$j]" "$cleaned_file")
          if [[ -n "$static_ip" && "$static_ip" != "null" ]]; then
            echo "      lan-ipv4:" >> "$out_compose"
            echo "        ipv4_address: \"${static_ip%%/*}\"" >> "$out_compose"
            last_octet=$(echo "${static_ip%%/*}" | awk -F. '{print $4}')
            hex_octet=$(printf "%02x" "$last_octet")
            echo "        mac_address: \"02:00:10:02:03:${hex_octet}\"" >> "$out_compose"
          fi
        done
      fi
    done
  fi

  echo "" >> "$out_compose"
  echo "networks:" >> "$out_compose"
  echo "  ix-apps:" >> "$out_compose"
  echo "    name: ix-apps" >> "$out_compose"
  echo "    external: true" >> "$out_compose"
  if [[ "$num_ext_ifaces" -gt 0 ]]; then
    echo "  lan-ipv4:" >> "$out_compose"
    echo "    name: lan-ipv4" >> "$out_compose"
    echo "    external: true" >> "$out_compose"
  fi

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

