#!/usr/bin/env bash
# Deploy VM Insights DCRs and assign Azure Policy for automatic AMA + DCR association
# Usage: ./deploy.sh [env-file]

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
    LOG_ANALYTICS_RESOURCE_GROUP
    LOG_ANALYTICS_WORKSPACE_NAME
    MONITOR_WORKSPACE_RESOURCE_GROUP
    MONITOR_WORKSPACE_NAME
    DCR_RESOURCE_GROUP
    POLICY_SCOPE_RESOURCE_GROUP
)

for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

# Build resource IDs
WORKSPACE_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${LOG_ANALYTICS_RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${LOG_ANALYTICS_WORKSPACE_NAME}"
MONITORING_ACCOUNT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${MONITOR_WORKSPACE_RESOURCE_GROUP}/providers/Microsoft.Monitor/accounts/${MONITOR_WORKSPACE_NAME}"

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID"

LOCATION="${LOCATION:-westus2}"

# -------------------------------------------------------
# Step 1: Ensure Log Analytics workspace exists
# -------------------------------------------------------
echo "Checking Log Analytics workspace: $LOG_ANALYTICS_WORKSPACE_NAME in RG: $LOG_ANALYTICS_RESOURCE_GROUP"

if az monitor log-analytics workspace show \
    --workspace-name "$LOG_ANALYTICS_WORKSPACE_NAME" \
    --resource-group "$LOG_ANALYTICS_RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
    echo "  Log Analytics workspace already exists."
else
    echo "  Creating Log Analytics workspace..."
    az monitor log-analytics workspace create \
        --workspace-name "$LOG_ANALYTICS_WORKSPACE_NAME" \
        --resource-group "$LOG_ANALYTICS_RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --location "$LOCATION"
    echo "  Log Analytics workspace created."
fi

# -------------------------------------------------------
# Step 2: Ensure Azure Monitor workspace exists
# -------------------------------------------------------
echo "Checking Azure Monitor workspace: $MONITOR_WORKSPACE_NAME in RG: $MONITOR_WORKSPACE_RESOURCE_GROUP"

if az monitor account show \
    --name "$MONITOR_WORKSPACE_NAME" \
    --resource-group "$MONITOR_WORKSPACE_RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
    echo "  Azure Monitor workspace already exists."
else
    echo "  Creating Azure Monitor workspace..."
    az monitor account create \
        --name "$MONITOR_WORKSPACE_NAME" \
        --resource-group "$MONITOR_WORKSPACE_RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --location "$LOCATION"
    echo "  Azure Monitor workspace created."
fi

# Build resource IDs
WORKSPACE_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${LOG_ANALYTICS_RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${LOG_ANALYTICS_WORKSPACE_NAME}"
MONITORING_ACCOUNT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${MONITOR_WORKSPACE_RESOURCE_GROUP}/providers/Microsoft.Monitor/accounts/${MONITOR_WORKSPACE_NAME}"

# -------------------------------------------------------
# Step 3: Deploy the Data Collection Rules via Bicep
# -------------------------------------------------------
DCR_PREFIX="${DCR_NAME_PREFIX:-vm-insights-ready}"

echo "Deploying VM Insights Data Collection Rules..."

az deployment group create \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$DCR_RESOURCE_GROUP" \
    --template-file bicep/vm-insights-dcr.bicep \
    --name "vm-insights-dcr-deploy" \
    --parameters \
        location="$LOCATION" \
        dcrNamePrefix="$DCR_PREFIX" \
        workspaceResourceId="$WORKSPACE_RESOURCE_ID" \
        monitoringAccountResourceId="$MONITORING_ACCOUNT_RESOURCE_ID"

echo "Data Collection Rules deployed successfully."

# -------------------------------------------------------
# Step 4: Assign Azure Policy for automatic AMA install + DCR association
# -------------------------------------------------------
echo ""
echo "Assigning Azure Policy for automatic AMA install and DCR association in RG: $POLICY_SCOPE_RESOURCE_GROUP"

SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${POLICY_SCOPE_RESOURCE_GROUP}"
DCR_LOGS_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${DCR_RESOURCE_GROUP}/providers/Microsoft.Insights/dataCollectionRules/${DCR_PREFIX}-dcr"
DCR_OTEL_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${DCR_RESOURCE_GROUP}/providers/Microsoft.Insights/dataCollectionRules/${DCR_PREFIX}-otel-dcr"

# Built-in initiative: Configure Windows machines to run Azure Monitor Agent
# and associate them to a Data Collection Rule
# Reference: https://learn.microsoft.com/en-us/azure/azure-arc/servers/deploy-ama-policy
POLICY_DEF_ID="/providers/Microsoft.Authorization/policySetDefinitions/9575b8b7-78ab-4281-b53b-d3c1ace2260b"

echo "  Using policy initiative: $POLICY_DEF_ID"

# Assign for logs-based DCR
az policy assignment create \
    --name "vm-insights-dcr-logs-association" \
    --display-name "VM Insights: AMA + logs DCR association" \
    --policy-set-definition "$POLICY_DEF_ID" \
    --scope "$SCOPE" \
    --mi-system-assigned \
    --location "${LOCATION:-westus2}" \
    --params "{\"DcrResourceId\": {\"value\": \"${DCR_LOGS_ID}\"}}"
echo "  Assigned policy initiative for logs-based DCR"

# Assign for OTel DCR
az policy assignment create \
    --name "vm-insights-dcr-otel-association" \
    --display-name "VM Insights: AMA + OTel DCR association" \
    --policy-set-definition "$POLICY_DEF_ID" \
    --scope "$SCOPE" \
    --mi-system-assigned \
    --location "${LOCATION:-westus2}" \
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
echo "Deployment complete."
echo "Azure Policy will automatically install AMA and associate DCRs with Arc-enabled Windows servers in RG '$POLICY_SCOPE_RESOURCE_GROUP'."
