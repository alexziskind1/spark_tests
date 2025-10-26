#!/usr/bin/env bash
# nccl_env_select.sh — pick an active CX-7 interface, export env for NCCL/UCX/MPI
# Source this file to persist exports in your current shell.
#   source ./nccl_env_select.sh
# You can pre-set IFACE/IP to skip the picker:
#   IFACE=enp1s0f1np1 IP=169.254.12.34 source ./nccl_env_select.sh

set -euo pipefail

# ---- Basics (adjust if your paths differ) ----
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
if [[ -d /usr/lib/aarch64-linux-gnu/openmpi ]]; then
  export MPI_HOME="${MPI_HOME:-/usr/lib/aarch64-linux-gnu/openmpi}"
else
  export MPI_HOME="${MPI_HOME:-/usr/lib/x86_64-linux-gnu/openmpi}"
fi
export NCCL_HOME="${NCCL_HOME:-$HOME/nccl/build}"

_pick_iface() {
  if ! command -v ibdev2netdev >/dev/null 2>&1; then
    echo "ERROR: ibdev2netdev not found. Install Mellanox OFED / NVIDIA net tools." >&2
    return 1
  fi

  mapfile -t RAW < <(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print $0}')
  if [[ ${#RAW[@]} -eq 0 ]]; then
    echo "No CX-7 ports are Up according to ibdev2netdev."
    echo "Bring a port up and add an IP, then rerun."
    return 2
  fi

  # Extract netdev name (right side after ==> ... (Up))
  IFACES=()
  for L in "${RAW[@]}"; do
    # shellcheck disable=SC2001
    CAND="$(echo "$L" | sed -E 's/.*==>\s*([a-zA-Z0-9_.:-]+)\s*\(Up\).*/\1/')"
    IFACES+=("$CAND")
  done

  # De-duplicate while preserving order
  UNIQUE=()
  declare -A seen=()
  for i in "${IFACES[@]}"; do
    [[ ${seen["$i"]+x} ]] || { UNIQUE+=("$i"); seen["$i"]=1; }
  done

  echo "Select the interface to use:"
  for i in "${!UNIQUE[@]}"; do
    idx=$((i+1))
    ip4=$(ip -4 addr show "${UNIQUE[$i]}" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
    ip4=${ip4:-"(no IPv4)"}
    # mark favorites (enp1…) visually
    fav=""
    [[ "${UNIQUE[$i]}" =~ ^enp1 ]] && fav=" *preferred"
    printf "  %2d) %-16s %-18s%s\n" "$idx" "${UNIQUE[$i]}" "$ip4" "$fav"
  done
  echo "  0) Cancel"

  while true; do
    read -r -p "Enter number: " CH
    [[ "$CH" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    if (( CH == 0 )); then
      return 3
    fi
    if (( CH >= 1 && CH <= ${#UNIQUE[@]} )); then
      SEL="${UNIQUE[$((CH-1))]}"
      echo "Chosen: $SEL"
      IFACE="$SEL"
      export IFACE
      break
    else
      echo "Out of range."
    fi
  done
}

# If IFACE not preset, run picker
IFACE="${IFACE:-}"
if [[ -z "$IFACE" ]]; then
  _pick_iface || return $?
fi

# Derive IPv4 if not preset
IP="${IP:-}"
if [[ -z "$IP" ]]; then
  _cidr="$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')"
  if [[ -n "$_cidr" ]]; then
    IP="${_cidr%%/*}"
  else
    echo "WARNING: No IPv4 found on $IFACE. UCX/NCCL may not work until an IP is assigned."
  fi
fi

# Core exports for networking
[[ -n "${IFACE:-}" ]] && export UCX_NET_DEVICES="$IFACE" \
                             NCCL_SOCKET_IFNAME="$IFACE" \
                             OMPI_MCA_btl_tcp_if_include="$IFACE"
[[ -n "${IP:-}"    ]] && export SPARK_LOCAL_IP="$IP"

# Libraries
LD_MERGED="$NCCL_HOME/lib:$CUDA_HOME/lib64:$MPI_HOME/lib"
[[ -n "${LD_LIBRARY_PATH:-}" ]] && LD_MERGED="$LD_MERGED:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$LD_MERGED"

# Sensible defaults
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export NCCL_IB_CUDA_SUPPORT=1
export NCCL_NET_GDR_LEVEL="${NCCL_NET_GDR_LEVEL:-2}"

echo "[NCCL env] IFACE=${IFACE:-<unset>}  IP=${IP:-<unset>}  CUDA_HOME=$CUDA_HOME"
