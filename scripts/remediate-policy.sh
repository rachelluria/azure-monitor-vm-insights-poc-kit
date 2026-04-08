#!/usr/bin/env bash
# Create remediation tasks for VM Insights policy assignments
# This triggers evaluation and remediation of existing Arc-enabled servers
# that are not yet compliant with the AMA install + DCR association policies.
# Usage: ./remediate-policy.sh [env-file]

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
    POLICY_SCOPE_RESOURCE_GROUP
)

for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID"

SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${POLICY_SCOPE_RESOURCE_GROUP}"

# The initiative contains these policy definition references:
#   deployAzureMonitoringAgentWindows       - AMA on Windows VMs
#   deployAzureMonitorAgentWindowsVMSS      - AMA on Windows VMSS
#   deployAzureMonitorAgentWindowsHybridVM  - AMA on Arc-enabled Windows servers
#   associateDataCollectionRuleWindows       - DCR association
#
# For Arc-enabled servers, we remediate the hybrid VM agent install
# and the DCR association policies.

POLICY_REFS=("deployAzureMonitorAgentWindowsHybridVM" "associateDataCollectionRuleWindows")
ASSIGNMENTS=("vm-insights-dcr-logs-association" "vm-insights-dcr-otel-association")

echo "Creating remediation tasks for VM Insights policy assignments in RG: $POLICY_SCOPE_RESOURCE_GROUP"
echo ""

for assignment in "${ASSIGNMENTS[@]}"; do
    for ref in "${POLICY_REFS[@]}"; do
        REMEDIATION_NAME="${assignment}-${ref}"
        # Truncate to 64 chars (Azure limit for remediation names)
        REMEDIATION_NAME="${REMEDIATION_NAME:0:64}"

        echo "  Creating remediation: $REMEDIATION_NAME"
        az policy remediation create \
            --name "$REMEDIATION_NAME" \
            --policy-assignment "$assignment" \
            --definition-reference-id "$ref" \
            --resource-group "$POLICY_SCOPE_RESOURCE_GROUP" \
            --query "{name:name, status:provisioningState, policyRef:policyDefinitionReferenceId}" \
            -o table
    done
    echo ""
done

echo "Remediation tasks created. Azure will evaluate and remediate non-compliant resources."
echo "Check progress in the Azure Portal under Policy > Remediation, or run:"
echo "  az policy remediation list --resource-group $POLICY_SCOPE_RESOURCE_GROUP -o table"
