# kube-iperf3-benchmark

A shell script that deploys [iperf3](https://iperf.fr/) as a Kubernetes DaemonSet, runs node-to-node TCP throughput benchmarks across all pod pairs, and exports the full results to a structured JSON file — including raw iperf3 output, extracted metrics, and a summary.

Designed for **RKE2** clusters but works with any Kubernetes distribution.

---

## What it tests

The script tests **pod IP to pod IP** traffic across all directional pairs. This bypasses kube-proxy and ClusterIP services entirely, giving you a clean measurement of your **overlay network** performance (VXLAN, WireGuard, etc.).

For each pair it records:

| Metric | Description |
|---|---|
| `mbps` | Throughput in Megabits per second |
| `bits_per_second` | Raw throughput value from iperf3 |
| `bytes_transferred` | Total bytes sent during the test |
| `retransmits` | TCP retransmissions — indicator of congestion or MTU issues |
| `cpu_host_pct` | CPU used by the sender during the test |
| `cpu_remote_pct` | CPU used by the receiver during the test |

> **Note:** iperf3 measures throughput only. It does not measure latency, DNS resolution, kube-proxy routing, or real application traffic patterns.

---

## Requirements

- `kubectl` configured and pointing at your target cluster
- `jq` installed on the machine running the script
- Sufficient RBAC to create DaemonSets and exec into pods in the target namespace

---

## Usage

```bash
# Clone the repo
git clone https://github.com/<your-org>/kube-iperf3-benchmark.git
cd kube-iperf3-benchmark

# Make executable
chmod +x k8s-iperf3-benchmark.sh

# Run with defaults (30s per test, namespace: default)
./k8s-iperf3-benchmark.sh
```

The output file is automatically named after your cluster and timestamp:

```
iperf3-results-<cluster-name>-<YYYYMMDD-HHMMSS>.json
```

---

## Configuration

All options are set via environment variables — no flags needed.

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `default` | Kubernetes namespace to deploy into |
| `DURATION` | `30` | iperf3 test duration in seconds |
| `PARALLEL` | `1` | Number of parallel iperf3 streams (`-P`) |
| `WAIT_TIMEOUT` | `120` | Seconds to wait for DaemonSet readiness |
| `OUTPUT_FILE` | auto-named | Override the output JSON filename |
| `CLEANUP_ON_EXIT` | `true` | Delete the DaemonSet after the script finishes |

**Examples:**

```bash
# Longer test duration and multiple parallel streams
DURATION=60 PARALLEL=4 ./k8s-iperf3-benchmark.sh

# Different namespace, keep the DaemonSet alive after run
NAMESPACE=network-test CLEANUP_ON_EXIT=false ./k8s-iperf3-benchmark.sh

# Custom output file
OUTPUT_FILE=my-results.json ./k8s-iperf3-benchmark.sh
```

---

## Output JSON structure

```json
{
  "schema_version": "1.0",
  "benchmark": {
    "start": "2026-04-20T15:21:36Z",
    "end": "2026-04-20T15:24:12Z",
    "namespace": "default",
    "config": {
      "duration_seconds": 30,
      "parallel_streams": 1,
      "pod_count": 3
    }
  },
  "summary": {
    "total_tests": 6,
    "successful_tests": 6,
    "failed_tests": 0,
    "throughput_mbps": {
      "min": 4527.35,
      "avg": 5243.18,
      "max": 5766.62
    },
    "total_retransmits": 2087
  },
  "results": [
    {
      "source": { "pod": "iperf3-benchmark-97snz", "node": "rnchr-03" },
      "destination": { "pod": "iperf3-benchmark-bg4hk", "node": "rnchr-02", "ip": "10.42.119.83" },
      "status": "success",
      "error": "",
      "timing": { "start": "...", "end": "..." },
      "metrics": {
        "bits_per_second": 4648660000,
        "mbps": 4648.66,
        "bytes_transferred": 17432150000,
        "retransmits": 48,
        "cpu_host_pct": 12.3,
        "cpu_remote_pct": 8.7
      },
      "raw": { }
    }
  ]
}
```

Each entry in `results` also contains the full `raw` iperf3 JSON output for further processing.

---

## Interpreting results

**Throughput** values of 4,500–9,000+ Mbps are expected on 10G infrastructure. Significantly lower values can indicate CPU bottlenecks on the overlay encapsulation or network congestion.

**Retransmits** of a few dozen per test are normal. Hundreds or thousands on a specific node pair point to packet loss, MTU fragmentation, or congestion on that path — worth investigating with `ping -M do -s 8972` to probe the MTU.

**Asymmetric results** (A→B notably different from B→A) can indicate NIC driver issues, interrupt affinity imbalance, or one-sided congestion.

**Failed tests** with `proxy error ... code 502` on `kubectl exec` are a kubelet reachability issue on that node — unrelated to the overlay network itself. Check `systemctl status rke2-agent` on the affected node.

---

## How it works

1. Deploys iperf3 as a DaemonSet (one pod per node, tolerating all taints)
2. Waits until all pods are Ready
3. Discovers all pod IPs and node names via `kubectl get pods`
4. For every directional pair (A→B and B→A), runs `iperf3 -c <pod-ip> --json` from inside the source pod
5. Streams raw JSON output to a temp file — never through shell arguments — to avoid hitting the OS `ARG_MAX` limit on large clusters
6. Assembles all results into a single JSON file using `jq --slurpfile`
7. Cleans up the DaemonSet on exit (configurable)

---

## License

MIT