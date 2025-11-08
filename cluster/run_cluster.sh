#!/bin/bash
# =============================================================================
# run_cluster.sh — auto-detect the right NIC/IP and launch a Ray node in Docker
# Usage:
#   run_cluster.sh <DOCKER_IMAGE> <HEAD_NODE_ADDRESS> <--head|--worker> <HF_HOME> [additional docker args...]
#
# Examples:
#   # Head:
#   run_cluster.sh nvcr.io/nvidia/vllm:25.09-py3 10.0.0.10 --head ~/.cache/huggingface -e FOO=bar
#
#   # Worker:
#   run_cluster.sh nvcr.io/nvidia/vllm:25.09-py3 10.0.0.10 --worker ~/.cache/huggingface
#
# Env overrides:
#   MN_IF_NAME     : force a specific NIC, e.g. enp1s0f0np0
#   VLLM_HOST_IP   : force this node's IP advertised to Ray
#   CONTAINER_NAME : set container name (default: node-$RANDOM)
# =============================================================================
 
set -euo pipefail
 
if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <DOCKER_IMAGE> <HEAD_NODE_ADDRESS> <--head|--worker> <HF_HOME> [extra docker args...]"
  exit 64
fi
 
DOCKER_IMAGE=$1
HEAD_NODE_ADDRESS=$2      # ignored for --head, required for --worker (or set HEAD_NODE_IP env)
NODE_TYPE=$3              # --head | --worker
PATH_TO_HF_HOME=$4
shift 4
ADDITIONAL_ARGS=("$@")
 
#CONTAINER_NAME="${CONTAINER_NAME:-node-${RANDOM}}"
CONTAINER_NAME="${CONTAINER_NAME:-ray-node}"
 
# -----------------------------------------------------------------------------
# Cleanup on exit
# -----------------------------------------------------------------------------
cleanup() {
  echo "Stopping and removing container ${CONTAINER_NAME}..."
  docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rm   "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
 
# -----------------------------------------------------------------------------
# Helper: pick the NIC that routes to the head (useful for workers)
# -----------------------------------------------------------------------------
route_nic_to_head() {
  local dst="$1"
  ip -o route get "$dst" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
 
# -----------------------------------------------------------------------------
# Decide ACTIVE_IF (NIC)
# Priority: MN_IF_NAME (env) -> route-to-head (workers) -> first UP CX-7-style NIC -> any UP ethernet
# -----------------------------------------------------------------------------
ACTIVE_IF=""
if [[ -n "${MN_IF_NAME:-}" ]]; then
  ACTIVE_IF="$MN_IF_NAME"
elif [[ "$NODE_TYPE" == "--worker" ]]; then
  # try to choose the NIC that actually reaches the head
  ACTIVE_IF="$(route_nic_to_head "${HEAD_NODE_ADDRESS}")" || true
fi
 
# Fallbacks if still empty
if [[ -z "${ACTIVE_IF}" || "${ACTIVE_IF}" == "lo" ]]; then
  # prefer CX-7 naming first if present and UP
  ACTIVE_IF=$(ip -br addr show | awk '/enp[0-9]+s0f[01]np[01].*UP/ {print $1; exit}') || true
fi
if [[ -z "${ACTIVE_IF}" || "${ACTIVE_IF}" == "lo" ]]; then
  # any up ethernet-like interface
  ACTIVE_IF=$(ip -br addr show | awk '/^e.*\s+UP/ {print $1; exit}') || true
fi
 
if [[ -z "${ACTIVE_IF}" || "${ACTIVE_IF}" == "lo" ]]; then
  echo "❌ Could not determine an active non-loopback interface. Set MN_IF_NAME explicitly."
  exit 1
fi
 
# -----------------------------------------------------------------------------
# Decide ACTIVE_IP (this node's advertised IP)
# Priority: VLLM_HOST_IP (env) -> first global IPv4 on ACTIVE_IF -> any IPv4 on ACTIVE_IF (incl. 169.254)
# As a last resort on worker: IP bound to route to head
# -----------------------------------------------------------------------------
if [[ -n "${VLLM_HOST_IP:-}" ]]; then
  ACTIVE_IP="$VLLM_HOST_IP"
else
  ACTIVE_IP=$(ip -o -4 addr show dev "$ACTIVE_IF" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1) || true
  if [[ -z "${ACTIVE_IP:-}" ]]; then
    # allow link-local if that's what you really use
    ACTIVE_IP=$(ip -o -4 addr show dev "$ACTIVE_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1) || true
  fi
  if [[ -z "${ACTIVE_IP:-}" && "$NODE_TYPE" == "--worker" ]]; then
    # extract src address used to reach head (ip route get …)
    ACTIVE_IP=$(ip -o route get "$HEAD_NODE_ADDRESS" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  fi
fi
 
if [[ -z "${ACTIVE_IP:-}" ]]; then
  echo "❌ Could not determine an IPv4 address for ${ACTIVE_IF}. Set VLLM_HOST_IP explicitly."
  exit 1
fi
 
export VLLM_HOST_IP="$ACTIVE_IP"
echo "✅ Using interface: ${ACTIVE_IF}"
echo "✅ Using IP:        ${VLLM_HOST_IP}"
 
# -----------------------------------------------------------------------------
# Validate head/worker inputs
# -----------------------------------------------------------------------------
if [[ "$NODE_TYPE" != "--head" && "$NODE_TYPE" != "--worker" ]]; then
  echo "❌ Node type must be --head or --worker (got: ${NODE_TYPE})"
  exit 64
fi
if [[ "$NODE_TYPE" == "--worker" && -z "${HEAD_NODE_ADDRESS}" ]]; then
  echo "❌ Worker requires HEAD_NODE_ADDRESS (IP or hostname of the head node)."
  exit 64
fi
 
# -----------------------------------------------------------------------------
# Build Ray start command
# -----------------------------------------------------------------------------
RAY_PORT=6379
RAY_START_CMD="ray start --block --node-ip-address=${VLLM_HOST_IP}"
if [[ "${NODE_TYPE}" == "--head" ]]; then
  RAY_START_CMD+=" --head --port=${RAY_PORT} --dashboard-host=0.0.0.0"
else
  # Allow HEAD_NODE_IP via env to override the positional arg
  HEAD_ADDR="${HEAD_NODE_IP:-$HEAD_NODE_ADDRESS}"
  RAY_START_CMD+=" --address=${HEAD_ADDR}:${RAY_PORT}"
fi
 
echo "Starting Ray with:"
echo "  ${RAY_START_CMD}"
echo "Container name: ${CONTAINER_NAME}"
 
# -----------------------------------------------------------------------------
# Docker launch
# -----------------------------------------------------------------------------
docker run \
  --entrypoint /bin/bash \
  --network host \
  --name "${CONTAINER_NAME}" \
  --shm-size 10.24g \
  --gpus all \
  -v "${PATH_TO_HF_HOME}:/root/.cache/huggingface" \
  -e RAY_NODE_IP_ADDRESS="${VLLM_HOST_IP}" \
  -e RAY_OVERRIDE_NODE_IP_ADDRESS="${VLLM_HOST_IP}" \
  -e RAY_DASHBOARD_HOST="0.0.0.0" \
  -e UCX_NET_DEVICES="${ACTIVE_IF}" \
  -e NCCL_SOCKET_IFNAME="${ACTIVE_IF}" \
  -e OMPI_MCA_btl_tcp_if_include="${ACTIVE_IF}" \
  -e GLOO_SOCKET_IFNAME="${ACTIVE_IF}" \
  -e TP_SOCKET_IFNAME="${ACTIVE_IF}" \
  "${ADDITIONAL_ARGS[@]}" \
  "${DOCKER_IMAGE}" -c "${RAY_START_CMD}"
