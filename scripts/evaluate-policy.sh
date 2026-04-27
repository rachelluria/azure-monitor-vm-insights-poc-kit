#!/usr/bin/env bash
# Trigger an on-demand Azure Policy compliance scan and report results
# for the VM Insights policy assignments.
#
# Usage: ./evaluate-policy.sh [env-file] [--wait]
#   env-file  Path to env file (default: config/poc.env)
#   --wait    Block until the scan finishes before reporting (default: async)
#
# Notes:
#   * The Azure Policy aggregator only refreshes the "latest" compliance
#     dataset on its own cadence (~24h) or after a trigger-scan completes.
#     A subscription/RG-scoped scan typically takes 10-30 minutes to fully
#     populate the portal's "Resources" tab.
#   * Use --wait when you want the script to block until the scan is done.

set -euo pipefail

ENV_FILE="config/poc.env"
WAIT_FOR_SCAN=false

for arg in "$@"; do
    case "$arg" in
        --wait)
            WAIT_FOR_SCAN=true
            ;;
        *)
            ENV_FILE="$arg"
            ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file not found: $ENV_FILE"
    echo "Copy config/poc.env.template to config/poc.env and fill in the values."
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

required=(
    SUBSCRIPTION_ID
    POLICY_SCOPE_RESOURCE_GROUP
)

for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

az account set --subscription "$SUBSCRIPTION_ID"

ASSIGNMENTS=("vm-insights-dcr-logs-association" "vm-insights-dcr-otel-association")

echo "Triggering policy compliance scan for resource group: $POLICY_SCOPE_RESOURCE_GROUP"
if [[ "$WAIT_FOR_SCAN" == "true" ]]; then
    echo "  (--wait set: blocking until scan completes; this can take 10-30 min)"
    az policy state trigger-scan --resource-group "$POLICY_SCOPE_RESOURCE_GROUP"
else
    az policy state trigger-scan --resource-group "$POLICY_SCOPE_RESOURCE_GROUP" --no-wait
    echo "  Scan running asynchronously. Re-run with --wait to block, or wait"
    echo "  10-30 min before relying on the compliance results below."
fi
echo ""

echo "Current remediation tasks:"
az policy remediation list \
    --resource-group "$POLICY_SCOPE_RESOURCE_GROUP" \
    --query "[?starts_with(name, 'vm-insights')].{name:name, state:properties.provisioningState, deployStatus:properties.deploymentStatus}" \
    -o table || true
echo ""

echo "Compliance summary per VM Insights assignment:"
FILTER=""
for assignment in "${ASSIGNMENTS[@]}"; do
    [[ -n "$FILTER" ]] && FILTER+=" or "
    FILTER+="PolicyAssignmentName eq '${assignment}'"
done

az policy state summarize \
    --resource-group "$POLICY_SCOPE_RESOURCE_GROUP" \
    --filter "$FILTER" \
    --query "policyAssignments[].{assignment:policyAssignmentId, nonCompliantResources:results.nonCompliantResources, nonCompliantPolicies:results.nonCompliantPolicies}" \
    -o table || true
echo ""

echo "Per-resource compliance state (may be empty until the scan finishes):"
for assignment in "${ASSIGNMENTS[@]}"; do
    echo ""
    echo "  Assignment: $assignment"
    az policy state list \
        --resource-group "$POLICY_SCOPE_RESOURCE_GROUP" \
        --filter "PolicyAssignmentName eq '${assignment}'" \
        --top 200 \
        --query "[].{resource:resourceId, ref:policyDefinitionReferenceId, compliant:complianceState}" \
        -o table || true
done
echo ""

echo "Tip: if the per-resource table is empty, the aggregator hasn't finished yet."
echo "Re-run with: ./scripts/evaluate-policy.sh $ENV_FILE --wait"
