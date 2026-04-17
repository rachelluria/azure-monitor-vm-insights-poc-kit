#!/usr/bin/env bash
# Assign Azure Policy to automatically install AMA and associate DCRs with Arc-enabled servers
# Usage: ./assign-policy.sh [env-file]

set -euo pipefail

# Disable Git Bash / MSYS automatic POSIX-to-Windows path conversion.
# Without this, arguments like "/providers/Microsoft.Authorization/..." or
# "/subscriptions/<id>/..." are rewritten (e.g. "C:/Program Files/Git/providers/...")
# before being passed to az.cmd, which causes Azure CLI to send malformed URLs
# and ARM to respond with "MissingSubscription".
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

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
    LOCATION
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

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID"

# Ensure required resource providers are registered. An unregistered
# Microsoft.PolicyInsights provider is a known cause of "MissingSubscription".
for rp in Microsoft.PolicyInsights Microsoft.Insights Microsoft.Monitor; do
    state=$(az provider show --namespace "$rp" --subscription "$SUBSCRIPTION_ID" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$state" != "Registered" ]]; then
        echo "  Registering resource provider: $rp"
        az provider register --namespace "$rp" --subscription "$SUBSCRIPTION_ID" >/dev/null
    fi
done

echo "Assigning Azure Policy for automatic AMA install and DCR association in RG: $POLICY_SCOPE_RESOURCE_GROUP"

SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${POLICY_SCOPE_RESOURCE_GROUP}"
DCR_LOGS_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${DCR_RESOURCE_GROUP}/providers/Microsoft.Insights/dataCollectionRules/${DCR_PREFIX}-dcr"
DCR_OTEL_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${DCR_RESOURCE_GROUP}/providers/Microsoft.Insights/dataCollectionRules/${DCR_PREFIX}-otel-dcr"

# Built-in initiative: Configure Windows machines to run Azure Monitor Agent
# and associate them to a Data Collection Rule
# Reference: https://learn.microsoft.com/en-us/azure/azure-arc/servers/deploy-ama-policy
#
# Use the bare GUID. Two CLI bugs intersect here:
#   * Some older CLI versions resolve the bare GUID to a URL missing the
#     subscription, producing "MissingSubscription". Those versions are
#     uncommon now (2.50+ resolves it correctly).
#   * Passing the full /providers/.../policySetDefinitions/<guid> path triggers
#     a bug in az's ResolvePolicyId (policy.py) where it strips back to the
#     GUID, looks it up at subscription scope only, and crashes on None.get
#     with "PolicySetDefinitionNotFound" for built-in initiatives.
# The MSYS_NO_PATHCONV exports at the top of this script prevent Git Bash
# from mangling other path-like arguments (e.g. --scope "/subscriptions/...").
POLICY_DEF_ID="9575b8b7-78ab-4281-b53b-d3c1ace2260b"

echo "  Using policy initiative: $POLICY_DEF_ID"

# Assign for logs-based DCR
az policy assignment create \
    --name "vm-insights-dcr-logs-association" \
    --display-name "VM Insights: AMA + logs DCR association" \
    --policy-set-definition "$POLICY_DEF_ID" \
    --scope "$SCOPE" \
    --subscription "$SUBSCRIPTION_ID" \
    --mi-system-assigned \
    --location "$LOCATION" \
    --params "{\"DcrResourceId\": {\"value\": \"${DCR_LOGS_ID}\"}}"
echo "  Assigned policy initiative for logs-based DCR"

# Assign for OTel DCR
az policy assignment create \
    --name "vm-insights-dcr-otel-association" \
    --display-name "VM Insights: AMA + OTel DCR association" \
    --policy-set-definition "$POLICY_DEF_ID" \
    --scope "$SCOPE" \
    --subscription "$SUBSCRIPTION_ID" \
    --mi-system-assigned \
    --location "$LOCATION" \
    --params "{\"DcrResourceId\": {\"value\": \"${DCR_OTEL_ID}\"}}"
echo "  Assigned policy initiative for OTel DCR"

# Grant the policy managed identities the Monitoring Contributor role on the scope
for assignment_name in vm-insights-dcr-logs-association vm-insights-dcr-otel-association; do
    PRINCIPAL_ID=$(az policy assignment show \
        --name "$assignment_name" \
        --scope "$SCOPE" \
        --subscription "$SUBSCRIPTION_ID" \
        --query "identity.principalId" -o tsv)
    az role assignment create \
        --role "Monitoring Contributor" \
        --assignee-object-id "$PRINCIPAL_ID" \
        --assignee-principal-type "ServicePrincipal" \
        --scope "$SCOPE" \
        --subscription "$SUBSCRIPTION_ID" 2>/dev/null \
        && echo "  Granted Monitoring Contributor to $assignment_name managed identity" \
        || echo "  Role already assigned for $assignment_name"
done

echo ""
echo "Policy assignments complete."
echo "Azure Policy will automatically install AMA and associate DCRs with Arc-enabled Windows servers in RG '$POLICY_SCOPE_RESOURCE_GROUP'."
