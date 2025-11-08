#!/bin/bash

# Overall script to run all required vllm scripts in order on spark2
# Usage: bash run_vllm_spark2.sh

set -e  # Exit on error

echo "=========================================="
echo "Starting vLLM setup on spark2"
echo "=========================================="

# Step 1: HuggingFace login
echo ""
echo "Step 1: Running HuggingFace login..."
sh ./vllm_00_hf_login.sh
echo "✓ HuggingFace login completed"

# Step 2: Set environment variables
echo ""
echo "Step 2: Setting environment variables..."
source ./vllm_01_env_spark2.sh
echo "✓ Environment variables set:"
echo "  - VLLM_IMAGE: $VLLM_IMAGE"
echo "  - MN_IF_NAME: $MN_IF_NAME"
echo "  - CONTAINER_NAME: $CONTAINER_NAME"

# Step 3: Launch Ray cluster (worker node)
echo ""
echo "Step 3: Launching Ray cluster worker node on spark2..."
echo "Note: This will connect to the head node at 192.168.100.10"
bash ./vllm_02_rayspark2.sh
echo "✓ Ray cluster worker node launched"

echo ""
echo "=========================================="
echo "vLLM setup on spark2 completed"
echo "=========================================="
