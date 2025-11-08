#!/bin/bash

# Overall script to run all required vllm scripts in order on spark1
# Usage: bash run_vllm_spark1.sh

set -e  # Exit on error

echo "=========================================="
echo "Starting vLLM setup on spark1"
echo "=========================================="

# Step 1: HuggingFace login
echo ""
echo "Step 1: Running HuggingFace login..."
sh ./vllm_00_hf_login.sh
echo "✓ HuggingFace login completed"

# Step 2: Set environment variables
echo ""
echo "Step 2: Setting environment variables..."
source ./vllm_01_env_spark1.sh
echo "✓ Environment variables set:"
echo "  - VLLM_IMAGE: $VLLM_IMAGE"
echo "  - MN_IF_NAME: $MN_IF_NAME"
echo "  - CONTAINER_NAME: $CONTAINER_NAME"

# Step 3: Launch Ray cluster (head node)
echo ""
echo "Step 3: Launching Ray cluster head node on spark1..."
bash ./vllm_02_rayspark1.sh
echo "✓ Ray cluster head node launched"

# Step 4: Launch server (interactive)
echo ""
echo "Step 4: Launching vLLM server (interactive shell)..."
echo "Note: This will open an interactive shell in the container"
echo "Run 'exit' to leave the container when done"
echo ""
bash ./vllm_03_launch_server_spark1.sh

echo ""
echo "=========================================="
echo "vLLM setup on spark1 completed"
echo "=========================================="
