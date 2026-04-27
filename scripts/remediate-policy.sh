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
# For Arc-enabled servers, we remediate the hybrid VM agent install and the
# DCR association policies. Important: AMA is a singleton on each Arc machine.
# If both policy assignments simultaneously run their AMA-install remediation,
# the second one fails with HCRP409:
#   "An extension of type AzureMonitorWindowsAgent is still processing.
#    Only one instance of an extension may be in progress at a time."
# To avoid this, install AMA only once (under the first assignment) and run
# DCR association under both, since each assignment ties a different DCR to
# the same agent.

AMA_INSTALL_REF="deployAzureMonitorAgentWindowsHybridVM"
DCR_ASSOC_REF="associateDataCollectionRuleWindows"
ASSIGNMENTS=("vm-insights-dcr-logs-association" "vm-insights-dcr-otel-association")
AMA_INSTALL_ASSIGNMENT="${ASSIGNMENTS[0]}"

echo "Creating remediation tasks for VM Insights policy assignments in RG: $POLICY_SCOPE_RESOURCE_GROUP"
echo ""

API_VERSION="2021-10-01"

# Build a list of (assignment, policyRef) pairs:
#   * AMA install: only under AMA_INSTALL_ASSIGNMENT (avoids HCRP409 conflict)
#   * DCR association: under every assignment (each DCR must be linked)
declare -a REMEDIATION_PAIRS=()
REMEDIATION_PAIRS+=("${AMA_INSTALL_ASSIGNMENT}|${AMA_INSTALL_REF}")
for assignment in "${ASSIGNMENTS[@]}"; do
    REMEDIATION_PAIRS+=("${assignment}|${DCR_ASSOC_REF}")
done

for pair in "${REMEDIATION_PAIRS[@]}"; do
    assignment="${pair%%|*}"
    ref="${pair##*|}"
    ASSIGNMENT_ID="${SCOPE}/providers/Microsoft.Authorization/policyAssignments/${assignment}"

    REMEDIATION_NAME="${assignment}-${ref}"
    # Truncate to 64 chars (Azure limit for remediation names)
    REMEDIATION_NAME="${REMEDIATION_NAME:0:64}"

    REMEDIATION_URI="${SCOPE}/providers/Microsoft.PolicyInsights/remediations/${REMEDIATION_NAME}?api-version=${API_VERSION}"

    # Use az rest instead of `az policy remediation create` to work around
    # an Azure CLI bug where the command injects an unsupported
    # `policyTargets` field into the request body, causing the API to
    # respond with InvalidRequestContent:
    #   "Could not find member 'policyTargets' on object of type
    #    'CheckPolicyComplianceDefinition'"
    # The REST payload below contains only the fields the Policy Insights
    # API accepts, plus resourceDiscoveryMode=ReEvaluateCompliance so the
    # task re-scans before remediating.
    BODY=$(cat <<EOF
{
  "properties": {
    "policyAssignmentId": "${ASSIGNMENT_ID}",
    "policyDefinitionReferenceId": "${ref}",
    "resourceDiscoveryMode": "ReEvaluateCompliance"
  }
}
EOF
)

    echo "  Creating remediation: $REMEDIATION_NAME"
    az rest \
        --method put \
        --uri "$REMEDIATION_URI" \
        --body "$BODY" \
        --query "{name:name, status:properties.provisioningState, policyRef:properties.policyDefinitionReferenceId}" \
        -o table
done
echo ""

echo "Remediation tasks created. Azure will evaluate and remediate non-compliant resources."
echo "Check progress in the Azure Portal under Policy > Remediation, or run:"
echo "  az policy remediation list --resource-group $POLICY_SCOPE_RESOURCE_GROUP -o table"
