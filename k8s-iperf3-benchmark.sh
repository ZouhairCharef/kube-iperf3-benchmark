#!/usr/bin/env bash
# =============================================================================
# k8s-iperf3-benchmark.sh
# Deploys iperf3 as a DaemonSet, runs node-to-node overlay benchmarks,
# and exports all results to a structured JSON file.
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-default}"
DURATION="${DURATION:-30}"          # iperf3 test duration in seconds
PARALLEL="${PARALLEL:-1}"           # iperf3 parallel streams (-P)
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}" # seconds to wait for DaemonSet readiness
DAEMONSET_NAME="iperf3-benchmark"
LABEL_SELECTOR="app=${DAEMONSET_NAME}"

# Derive cluster name from the current kubectl context (sanitized for filenames)
CLUSTER_NAME=$(kubectl config current-context 2>/dev/null | tr '/:' '--' | tr -cd '[:alnum:]_.-')
CLUSTER_NAME="${CLUSTER_NAME:-unknown-cluster}"

OUTPUT_FILE="${OUTPUT_FILE:-iperf3-results-${CLUSTER_NAME}-$(date +%Y%m%d-%H%M%S).json}"

# Temp file holds one JSON result object per line (JSONL).
# All raw iperf3 output flows through pipes/files — never through shell args —
# so we never hit the OS ARG_MAX limit regardless of output size.
TEMP_RESULTS=$(mktemp /tmp/iperf3-results-XXXXXX.jsonl)

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Dependency checks ─────────────────────────────────────────────────────────
for cmd in kubectl jq; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found in PATH."
done

# ── Cleanup trap ──────────────────────────────────────────────────────────────
CLEANUP_ON_EXIT="${CLEANUP_ON_EXIT:-true}"
cleanup() {
  rm -f "$TEMP_RESULTS"
  if [[ "$CLEANUP_ON_EXIT" == "true" ]]; then
    warn "Cleaning up DaemonSet '${DAEMONSET_NAME}' in namespace '${NAMESPACE}'..."
    kubectl delete daemonset "$DAEMONSET_NAME" -n "$NAMESPACE" --ignore-not-found=true &>/dev/null || true
  fi
}
trap cleanup EXIT

# ── 1. Deploy DaemonSet ───────────────────────────────────────────────────────
log "Deploying iperf3 DaemonSet '${DAEMONSET_NAME}' in namespace '${NAMESPACE}'..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${DAEMONSET_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${DAEMONSET_NAME}
spec:
  selector:
    matchLabels:
      app: ${DAEMONSET_NAME}
  template:
    metadata:
      labels:
        app: ${DAEMONSET_NAME}
    spec:
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 5
      containers:
        - name: iperf3
          image: networkstatic/iperf3
          args: ["-s"]
          ports:
            - containerPort: 5201
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "128Mi"
EOF

# ── 2. Wait for DaemonSet to be Ready ─────────────────────────────────────────
log "Waiting up to ${WAIT_TIMEOUT}s for all DaemonSet pods to be Ready..."
DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT ))

while true; do
  DESIRED=$(kubectl get daemonset "$DAEMONSET_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  READY=$(kubectl get daemonset "$DAEMONSET_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)

  [[ "$DESIRED" -gt 0 && "$READY" -eq "$DESIRED" ]] && break

  if [[ $(date +%s) -gt $DEADLINE ]]; then
    die "Timed out waiting for DaemonSet. Desired=${DESIRED}, Ready=${READY}"
  fi
  log "  Waiting... Desired=${DESIRED}, Ready=${READY}"
  sleep 5
done
ok "All ${READY} pod(s) are Ready."

# ── 3. Collect pod info ───────────────────────────────────────────────────────
log "Collecting pod info..."

declare -a POD_NAMES POD_IPS POD_NODES
while IFS=$'\t' read -r name ip node; do
  POD_NAMES+=("$name")
  POD_IPS+=("$ip")
  POD_NODES+=("$node")
done < <(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\t"}{.spec.nodeName}{"\n"}{end}')

NUM_PODS=${#POD_NAMES[@]}
[[ $NUM_PODS -lt 2 ]] && die "Need at least 2 pods to run benchmarks. Found: ${NUM_PODS}"
log "Found ${NUM_PODS} pod(s) across nodes."

# ── 4. Run benchmarks (all unique pairs) ──────────────────────────────────────
log "Running iperf3 benchmarks for all pod pairs (duration=${DURATION}s, parallel=${PARALLEL})..."
log "This may take a while: $((NUM_PODS * (NUM_PODS - 1))) directional tests."

BENCHMARK_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for (( i=0; i<NUM_PODS; i++ )); do
  for (( j=0; j<NUM_PODS; j++ )); do
    [[ $i -eq $j ]] && continue

    SRC_POD="${POD_NAMES[$i]}"
    DST_IP="${POD_IPS[$j]}"
    SRC_NODE="${POD_NODES[$i]}"
    DST_NODE="${POD_NODES[$j]}"
    DST_POD="${POD_NAMES[$j]}"

    log "  [${SRC_NODE}] ${SRC_POD} → [${DST_NODE}] ${DST_POD} (${DST_IP})"

    TEST_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    STATUS="success"
    ERROR_MSG=""

    # Write raw iperf3 JSON directly to a temp file.
    # This is the critical fix: large JSON never passes through argv,
    # so the OS ARG_MAX limit cannot be hit.
    RAW_TMP=$(mktemp /tmp/iperf3-raw-XXXXXX.json)

    if ! kubectl exec -n "$NAMESPACE" "$SRC_POD" -- \
        iperf3 -c "$DST_IP" -t "$DURATION" -P "$PARALLEL" --json \
        > "$RAW_TMP" 2>&1; then
      STATUS="error"
      ERROR_MSG=$(cat "$RAW_TMP")
      echo '{}' > "$RAW_TMP"
      warn "    Test failed: ${ERROR_MSG:0:120}"
    fi

    TEST_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Extract scalar metrics from the file (small strings, safe as jq args)
    if [[ "$STATUS" == "success" ]]; then
      BITS_PER_SEC=$(jq -r '.end.sum_received.bits_per_second // 0' "$RAW_TMP")
      BYTES_TRANSFERRED=$(jq -r '.end.sum_received.bytes // 0'         "$RAW_TMP")
      RETRANSMITS=$(jq -r '.end.sum_sent.retransmits // 0'             "$RAW_TMP")
      CPU_HOST=$(jq -r '.end.cpu_utilization_percent.host_total // 0'  "$RAW_TMP")
      CPU_REMOTE=$(jq -r '.end.cpu_utilization_percent.remote_total // 0' "$RAW_TMP")
      MBPS=$(awk "BEGIN {printf \"%.2f\", ${BITS_PER_SEC}/1000000}")
      ok "    ✓ ${MBPS} Mbps | retransmits=${RETRANSMITS}"
    else
      BITS_PER_SEC=0; BYTES_TRANSFERRED=0; RETRANSMITS=0
      CPU_HOST=0; CPU_REMOTE=0; MBPS=0
    fi

    # Build the result object and append to JSONL file.
    # --slurpfile reads the raw JSON from disk — never from argv.
    jq -n \
      --arg     src_pod  "$SRC_POD" \
      --arg     src_node "$SRC_NODE" \
      --arg     dst_pod  "$DST_POD" \
      --arg     dst_node "$DST_NODE" \
      --arg     dst_ip   "$DST_IP" \
      --arg     status   "$STATUS" \
      --arg     err      "$ERROR_MSG" \
      --arg     t_start  "$TEST_START" \
      --arg     t_end    "$TEST_END" \
      --argjson bps      "$BITS_PER_SEC" \
      --argjson mbps     "$MBPS" \
      --argjson bytes    "$BYTES_TRANSFERRED" \
      --argjson retr     "$RETRANSMITS" \
      --argjson cpu_h    "$CPU_HOST" \
      --argjson cpu_r    "$CPU_REMOTE" \
      --slurpfile raw    "$RAW_TMP" \
      '{
        source:      { pod: $src_pod,  node: $src_node },
        destination: { pod: $dst_pod,  node: $dst_node, ip: $dst_ip },
        status:      $status,
        error:       $err,
        timing:      { start: $t_start, end: $t_end },
        metrics: {
          bits_per_second:   $bps,
          mbps:              $mbps,
          bytes_transferred: $bytes,
          retransmits:       $retr,
          cpu_host_pct:      $cpu_h,
          cpu_remote_pct:    $cpu_r
        },
        raw: $raw[0]
      }' >> "$TEMP_RESULTS"

    rm -f "$RAW_TMP"
  done
done

BENCHMARK_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── 5. Assemble final JSON + summary in one jq pass ───────────────────────────
log "Computing summary and writing results to '${OUTPUT_FILE}'..."

jq -n \
  --arg     version         "1.0" \
  --arg     benchmark_start "$BENCHMARK_START" \
  --arg     benchmark_end   "$BENCHMARK_END" \
  --arg     namespace       "$NAMESPACE" \
  --argjson duration        "$DURATION" \
  --argjson parallel        "$PARALLEL" \
  --argjson num_pods        "$NUM_PODS" \
  --slurpfile results       "$TEMP_RESULTS" \
  '
  ($results) as $r |
  {
    schema_version: $version,
    benchmark: {
      start:     $benchmark_start,
      end:       $benchmark_end,
      namespace: $namespace,
      config: {
        duration_seconds: $duration,
        parallel_streams: $parallel,
        pod_count:        $num_pods
      }
    },
    summary: {
      total_tests:      ($r | length),
      successful_tests: ([$r[] | select(.status=="success")] | length),
      failed_tests:     ([$r[] | select(.status=="error")]   | length),
      throughput_mbps: {
        min: ([$r[] | select(.status=="success") | .metrics.mbps] | if length>0 then min else 0 end),
        max: ([$r[] | select(.status=="success") | .metrics.mbps] | if length>0 then max else 0 end),
        avg: ([$r[] | select(.status=="success") | .metrics.mbps] | if length>0 then (add/length*100|round/100) else 0 end)
      },
      total_retransmits: ([$r[] | .metrics.retransmits] | add // 0)
    },
    results: $r
  }
  ' > "$OUTPUT_FILE"

ok "Done! Results saved to: ${OUTPUT_FILE}"

# ── 6. Print human-readable summary ───────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  iperf3 Benchmark Summary${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
jq -r '
  "  Namespace  : \(.benchmark.namespace)",
  "  Duration   : \(.benchmark.config.duration_seconds)s per test",
  "  Pod count  : \(.benchmark.config.pod_count)",
  "  Tests run  : \(.summary.total_tests) (\(.summary.successful_tests) ok, \(.summary.failed_tests) failed)",
  "",
  "  Throughput (Mbps):",
  "    Min : \(.summary.throughput_mbps.min)",
  "    Avg : \(.summary.throughput_mbps.avg)",
  "    Max : \(.summary.throughput_mbps.max)",
  "",
  "  Total retransmits: \(.summary.total_retransmits)"
' "$OUTPUT_FILE"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""
