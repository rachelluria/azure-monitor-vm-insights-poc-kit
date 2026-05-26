#!/usr/bin/env bash
# Deploy the Server Patch & Inventory Compliance workbook
# Usage: ./deploy-workbook.sh [env-file] [workbook-json-path]

set -euo pipefail

ENV_FILE="${1:-config/poc.env}"
WORKBOOK_FILE="${2:-workbooks/server-patch-inventory-compliance.workbook.json}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file not found: $ENV_FILE"
    echo "Copy config/poc.env.template to config/poc.env and fill in the values."
    exit 1
fi

if [[ ! -f "$WORKBOOK_FILE" ]]; then
    echo "Error: Workbook JSON not found: $WORKBOOK_FILE"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required variables
required=(
    SUBSCRIPTION_ID
    LOCATION
)
for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

# Workbook deployment settings (sensible defaults; override in poc.env if desired)
# Resolution order: explicit WORKBOOK_RESOURCE_GROUP → Log Analytics workspace RG → DCR RG.
WORKBOOK_RESOURCE_GROUP="${WORKBOOK_RESOURCE_GROUP:-${LOG_ANALYTICS_RESOURCE_GROUP:-${DCR_RESOURCE_GROUP:-}}}"
WORKBOOK_DISPLAY_NAME="${WORKBOOK_DISPLAY_NAME:-Server Patch & Inventory Compliance}"

if [[ -z "$WORKBOOK_RESOURCE_GROUP" ]]; then
    echo "Error: WORKBOOK_RESOURCE_GROUP (or LOG_ANALYTICS_RESOURCE_GROUP / DCR_RESOURCE_GROUP) must be set in $ENV_FILE."
    exit 1
fi

# Require a tool that can produce a deterministic GUID from the display name so
# re-running this script updates the same workbook instead of creating duplicates.
if ! command -v openssl &>/dev/null; then
    echo "Error: 'openssl' is required to derive a stable workbook GUID."
    exit 1
fi

WORKBOOK_GUID=$(printf "%s" "$WORKBOOK_DISPLAY_NAME" \
    | openssl dgst -md5 -hex \
    | awk '{print $NF}' \
    | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/')

az account set --subscription "$SUBSCRIPTION_ID"

# Ensure the target resource group exists
if ! az group show --name "$WORKBOOK_RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
    echo "Creating resource group: $WORKBOOK_RESOURCE_GROUP ($LOCATION)"
    az group create \
        --name "$WORKBOOK_RESOURCE_GROUP" \
        --location "$LOCATION" \
        --subscription "$SUBSCRIPTION_ID" >/dev/null
fi

# Build an inline ARM template wrapping the workbook JSON as serializedData.
# We use --parameters @file for serializedData to avoid shell-escaping the JSON body.
TEMPLATE_FILE="$(mktemp -t workbook-template-XXXXXX.json)"
PARAMS_FILE="$(mktemp -t workbook-params-XXXXXX.json)"
trap 'rm -f "$TEMPLATE_FILE" "$PARAMS_FILE"' EXIT

cat > "$TEMPLATE_FILE" <<'JSON'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "workbookName":        { "type": "string" },
    "workbookDisplayName": { "type": "string" },
    "workbookSerialized":  { "type": "string" },
    "location":            { "type": "string" }
  },
  "resources": [
    {
      "type": "Microsoft.Insights/workbooks",
      "apiVersion": "2022-04-01",
      "name": "[parameters('workbookName')]",
      "location": "[parameters('location')]",
      "kind": "shared",
      "properties": {
        "displayName":    "[parameters('workbookDisplayName')]",
        "serializedData": "[parameters('workbookSerialized')]",
        "version":        "1.0",
        "sourceId":       "azure monitor",
        "category":       "workbook"
      }
    }
  ],
  "outputs": {
    "workbookId":  { "type": "string", "value": "[resourceId('Microsoft.Insights/workbooks', parameters('workbookName'))]" }
  }
}
JSON

# Read the workbook JSON file as a single JSON-encoded string for serializedData.
# Prefer jq, fall back to python (which ships with az CLI anyway).
if command -v jq &>/dev/null; then
    SERIALIZED=$(jq -Rs . < "$WORKBOOK_FILE")
elif command -v python3 &>/dev/null; then
    SERIALIZED=$(python3 -c 'import json,sys; sys.stdout.write(json.dumps(open(sys.argv[1],encoding="utf-8").read()))' "$WORKBOOK_FILE")
elif command -v python &>/dev/null; then
    SERIALIZED=$(python -c 'import json,sys,io; sys.stdout.write(json.dumps(io.open(sys.argv[1],encoding="utf-8").read()))' "$WORKBOOK_FILE")
else
    echo "Error: need 'jq' or 'python3' (or 'python') to package the workbook JSON."
    exit 1
fi

cat > "$PARAMS_FILE" <<JSON
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "workbookName":        { "value": "$WORKBOOK_GUID" },
    "workbookDisplayName": { "value": "$WORKBOOK_DISPLAY_NAME" },
    "workbookSerialized":  { "value": $SERIALIZED },
    "location":            { "value": "$LOCATION" }
  }
}
JSON

echo "Deploying workbook:"
echo "  Display name : $WORKBOOK_DISPLAY_NAME"
echo "  Resource ID  : /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$WORKBOOK_RESOURCE_GROUP/providers/Microsoft.Insights/workbooks/$WORKBOOK_GUID"
echo "  Source file  : $WORKBOOK_FILE"

DEPLOYMENT_NAME="workbook-$(date +%Y%m%d-%H%M%S)"
az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$WORKBOOK_RESOURCE_GROUP" \
    --subscription "$SUBSCRIPTION_ID" \
    --template-file "$TEMPLATE_FILE" \
    --parameters "@$PARAMS_FILE" \
    --output table

WORKBOOK_RID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$WORKBOOK_RESOURCE_GROUP/providers/Microsoft.Insights/workbooks/$WORKBOOK_GUID"
PORTAL_URL="https://portal.azure.com/#@/resource${WORKBOOK_RID}"

echo
echo "Workbook deployed."
echo "  Open in portal: $PORTAL_URL"
