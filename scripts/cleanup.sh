#!/usr/bin/env bash
# Delete VM Insights DCRs and remove Azure Policy assignments
# Usage: ./cleanup.sh [env-file]

set -euo pipefail

ENV_FILE="${1:-config/poc.env}"

# Load environment variables from the env file
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file not found: $ENV_FILE"
    echo "Copy config/poc.env.template to config/poc.env and fill in the values."
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required variables
required=(
    SUBSCRIPTION_ID
    DCR_RESOURCE_GROUP
    POLICY_SCOPE_RESOURCE_GROUP
)

for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

DCR_PREFIX="${DCR_NAME_PREFIX:-vm-insights-ready}"
DCR_LOGS="${DCR_PREFIX}-dcr"
DCR_OTEL="${DCR_PREFIX}-otel-dcr"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${POLICY_SCOPE_RESOURCE_GROUP}"

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID"

# Step 1: Remove Azure Policy assignments
echo "Removing Azure Policy assignments..."

az policy assignment delete \
    --name "vm-insights-dcr-logs-association" \
    --scope "$SCOPE" 2>/dev/null \
    && echo "  Removed policy assignment: vm-insights-dcr-logs-association" \
    || echo "  vm-insights-dcr-logs-association not found, skipping"

az policy assignment delete \
    --name "vm-insights-dcr-otel-association" \
    --scope "$SCOPE" 2>/dev/null \
    && echo "  Removed policy assignment: vm-insights-dcr-otel-association" \
    || echo "  vm-insights-dcr-otel-association not found, skipping"

# Step 2: Delete the DCRs
echo ""
echo "Deleting DCR: $DCR_LOGS"
az monitor data-collection rule delete \
    --name "$DCR_LOGS" \
    --resource-group "$DCR_RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION_ID" \
    --yes 2>/dev/null \
    && echo "  Deleted $DCR_LOGS" \
    || echo "  $DCR_LOGS not found, skipping"

echo "Deleting DCR: $DCR_OTEL"
az monitor data-collection rule delete \
    --name "$DCR_OTEL" \
    --resource-group "$DCR_RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION_ID" \
    --yes 2>/dev/null \
    && echo "  Deleted $DCR_OTEL" \
    || echo "  $DCR_OTEL not found, skipping"

echo ""
echo "Cleanup complete."
