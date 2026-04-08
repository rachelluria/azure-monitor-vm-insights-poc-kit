#!/usr/bin/env bash
# Assign Azure Policy to automatically install AMA and associate DCRs with Arc-enabled servers
# Usage: ./assign-policy.sh [env-file]

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

LOCATION="${LOCATION:-westus2}"
DCR_PREFIX="${DCR_NAME_PREFIX:-vm-insights-ready}"

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID"

echo "Assigning Azure Policy for automatic AMA install and DCR association in RG: $POLICY_SCOPE_RESOURCE_GROUP"

SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${POLICY_SCOPE_RESOURCE_GROUP}"
DCR_LOGS_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${DCR_RESOURCE_GROUP}/providers/Microsoft.Insights/dataCollectionRules/${DCR_PREFIX}-dcr"
DCR_OTEL_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${DCR_RESOURCE_GROUP}/providers/Microsoft.Insights/dataCollectionRules/${DCR_PREFIX}-otel-dcr"

# Built-in initiative: Configure Windows machines to run Azure Monitor Agent
# and associate them to a Data Collection Rule
# Reference: https://learn.microsoft.com/en-us/azure/azure-arc/servers/deploy-ama-policy
# Note: Use GUID only — full resource path causes PolicySetDefinitionNotFound in some CLI versions
POLICY_DEF_ID="9575b8b7-78ab-4281-b53b-d3c1ace2260b"

echo "  Using policy initiative: $POLICY_DEF_ID"

# Assign for logs-based DCR
az policy assignment create \
    --name "vm-insights-dcr-logs-association" \
    --display-name "VM Insights: AMA + logs DCR association" \
    --policy-set-definition "$POLICY_DEF_ID" \
    --scope "$SCOPE" \
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
    --mi-system-assigned \
    --location "$LOCATION" \
    --params "{\"DcrResourceId\": {\"value\": \"${DCR_OTEL_ID}\"}}"
echo "  Assigned policy initiative for OTel DCR"

# Grant the policy managed identities the Monitoring Contributor role on the scope
for assignment_name in vm-insights-dcr-logs-association vm-insights-dcr-otel-association; do
    PRINCIPAL_ID=$(az policy assignment show --name "$assignment_name" --scope "$SCOPE" --query "identity.principalId" -o tsv)
    az role assignment create \
        --role "Monitoring Contributor" \
        --assignee-object-id "$PRINCIPAL_ID" \
        --assignee-principal-type "ServicePrincipal" \
        --scope "$SCOPE" 2>/dev/null \
        && echo "  Granted Monitoring Contributor to $assignment_name managed identity" \
        || echo "  Role already assigned for $assignment_name"
done

echo ""
echo "Policy assignments complete."
echo "Azure Policy will automatically install AMA and associate DCRs with Arc-enabled Windows servers in RG '$POLICY_SCOPE_RESOURCE_GROUP'."
