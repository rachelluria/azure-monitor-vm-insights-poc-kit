#!/usr/bin/env bash
# Create a remediation task for the IIS Hybrid Worker onboarding policy so that
# Arc-enabled Windows servers that ALREADY exist (and are not yet onboarded) get the
# Hybrid Worker extension installed and joined to the group.
#
# New machines are handled automatically by the DeployIfNotExists assignment; this script
# is only needed to sweep pre-existing machines once.
#
# Usage: ./remediate-hybrid-worker-policy.sh [env-file]

set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

ENV_FILE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/config/poc.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file not found: $ENV_FILE"
    echo "Copy config/poc.env.template to config/poc.env and fill in the values."
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

required=(SUBSCRIPTION_ID AUTOMATION_RESOURCE_GROUP)
for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

POLICY_SCOPE_RESOURCE_GROUP="${POLICY_SCOPE_RESOURCE_GROUP:-${ARC_RESOURCE_GROUP:-$AUTOMATION_RESOURCE_GROUP}}"
ASSIGNMENT_NAME="deploy-iis-hybrid-worker"
API_VERSION="2021-10-01"

az account set --subscription "$SUBSCRIPTION_ID"

SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${POLICY_SCOPE_RESOURCE_GROUP}"
ASSIGNMENT_ID="${SCOPE}/providers/Microsoft.Authorization/policyAssignments/${ASSIGNMENT_NAME}"
REMEDIATION_NAME="remediate-${ASSIGNMENT_NAME}"
REMEDIATION_URI="${SCOPE}/providers/Microsoft.PolicyInsights/remediations/${REMEDIATION_NAME}?api-version=${API_VERSION}"

# Single-definition policy, so no policyDefinitionReferenceId is needed.
# Use az rest to avoid the CLI's unsupported policyTargets field (see ../../scripts/remediate-policy.sh).
BODY=$(cat <<EOF
{
  "properties": {
    "policyAssignmentId": "${ASSIGNMENT_ID}",
    "resourceDiscoveryMode": "ReEvaluateCompliance"
  }
}
EOF
)

echo "Creating remediation task: $REMEDIATION_NAME"
az rest \
    --method put \
    --uri "$REMEDIATION_URI" \
    --body "$BODY" \
    --query "{name:name, status:properties.provisioningState}" \
    -o table

echo ""
echo "Remediation task created. Azure will install the Hybrid Worker extension on existing"
echo "non-compliant Arc-enabled Windows servers in '$POLICY_SCOPE_RESOURCE_GROUP'."
echo "Check progress:"
echo "  az policy remediation list --resource-group $POLICY_SCOPE_RESOURCE_GROUP -o table"
