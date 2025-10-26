#!/usr/bin/env bash
# nccl_env_select.sh — interactive picker for NCCL/UCX/MPI env
# Default: ALWAYS prompt, even if IFACE is already set.
# Use:     source ./nccl_env_select.sh          # interactive
#          source ./nccl_env_select.sh --auto   # use existing IFACE/IP or auto-pick first

set -euo pipefail

MODE="prompt"
if [[ "${1:-}" == "--auto" ]]; then
  MODE="auto"
fi

# ----- Basics (adjust if paths differ) -----
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
if [[ -d /usr/lib/aarch64-linux-gnu/openmpi ]]; then
  export MPI_HOME="${MPI_HOME:-/usr/lib/aarch64-linux-gnu/openmpi}"
else
  export MPI_HOME="${MPI_HOME:-/usr/lib/x86_64-linux-gnu/openmpi}"
fi
export NCCL_HOME="${NCCL_HOME:-$HOME/nccl/build}"

_pick_iface() {
  if ! command -v ibdev2netdev >/dev/null 2>&1; then
    echo "ERROR: ibdev2netdev not found (install NVIDIA/Mellanox net tools)." >&2
    return 1
  fi

  mapfile -t RAW < <(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print $0}')
  if [[ ${#RAW[@]} -eq 0 ]]; then
    echo "No CX-7 ports are Up according to ibdev2netdev."
    echo "Bring a port up and add an IP, then rerun."
    return 2
  fi

  # Extract netdev names and filter out enP2p* (we prefer enp1* on Spark)
  CANDIDATES=()
  for L in "${RAW[@]}"; do
    DEV="$(sed -E 's/.*==>\s*([a-zA-Z0-9_.:-]+)\s*\(Up\).*/\1/' <<<"$L")"
    [[ "$DEV" =~ ^enP2p ]] && continue
    CANDIDATES+=("$DEV")
  done
  # If nothing left after filter, fall back to all Up devs
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    for L in "${RAW[@]}"; do
      DEV="$(sed -E 's/.*==>\s*([a-zA-Z0-9_.:-]+)\s*\(Up\).*/\1/' <<<"$L")"
      CANDIDATES+=("$DEV")
    done
  fi

  # De-dup, keep order
  declare -A seen=()
  UNIQUE=()
  for d in "${CANDIDATES[@]}"; do
    [[ ${seen["$d"]+x} ]] || { UNIQUE+=("$d"); seen["$d"]=1; }
  done

  if [[ "$MODE" == "auto" ]]; then
    IFACE="${IFACE:-${UNIQUE[0]}}"
    export IFACE
    return 0
  fi

  echo "Select the interface to use:"
  for i in "${!UNIQUE[@]}"; do
    n=$((i+1))
    ip4=$(ip -4 addr show "${UNIQUE[$i]}" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
    ip4=${ip4:-"(no IPv4)"}
    fav=""
    [[ "${UNIQUE[$i]}" =~ ^enp1 ]] && fav=" *preferred"
    printf "  %2d) %-16s %-18s%s\n" "$n" "${UNIQUE[$i]}" "$ip4" "$fav"
  done
  echo "  0) Cancel"

  while true; do
    read -r -p "Enter number: " CH
    [[ "$CH" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    (( CH == 0 )) && return 3
    if (( CH >= 1 && CH <= ${#UNIQUE[@]} )); then
      IFACE="${UNIQUE[$((CH-1))]}"
      export IFACE
      echo "Chosen: $IFACE"
      break
    else
      echo "Out of range."
    fi
  done
}

# Always pick (unless --auto)
IFACE="${IFACE:-}"
if ! _pick_iface; then
  return $?
fi

# Derive IPv4 if not preset
IP="${IP:-}"
if [[ -z "$IP" ]]; then
  CIDR="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')"
  [[ -n "$CIDR" ]] && IP="${CIDR%%/*}" || IP=""
fi

# Core exports
[[ -n "$IFACE" ]] && export UCX_NET_DEVICES="$IFACE" \
                           NCCL_SOCKET_IFNAME="$IFACE" \
                           OMPI_MCA_btl_tcp_if_include="$IFACE"
[[ -n "$IP"    ]] && export SPARK_LOCAL_IP="$IP"

# Libraries
LD_MERGED="$NCCL_HOME/lib:$CUDA_HOME/lib64:$MPI_HOME/lib"
[[ -n "${LD_LIBRARY_PATH:-}" ]] && LD_MERGED="$LD_MERGED:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$LD_MERGED"

# Sensible defaults
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export NCCL_IB_CUDA_SUPPORT=1
export NCCL_NET_GDR_LEVEL="${NCCL_NET_GDR_LEVEL:-2}"

if [[ -z "$IP" ]]; then
  echo "WARNING: No IPv4 found on $IFACE. Assign an IP (e.g., link-local) before running NCCL/UCX."
fi
echo "[NCCL env] IFACE=${IFACE:-<unset>}  IP=${IP:-<unset>}  CUDA_HOME=$CUDA_HOME"
