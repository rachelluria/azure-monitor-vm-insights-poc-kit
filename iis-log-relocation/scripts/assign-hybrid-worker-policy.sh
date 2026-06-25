#!/usr/bin/env bash
# Deploy the IIS Hybrid Worker onboarding at scale via a custom Azure Policy
# (DeployIfNotExists). This mirrors the AMA policy pattern in ../../scripts/assign-policy.sh:
# create the definition, assign it with a system-assigned identity, and grant that identity
# the roles its remediation deployment needs.
#
# There is no built-in policy that installs the Hybrid Worker extension, so this script
# creates a custom definition from policy/onboard-hybrid-worker.rules.json.
#
# Usage: ./assign-hybrid-worker-policy.sh [env-file]

set -euo pipefail

# Disable Git Bash / MSYS automatic POSIX-to-Windows path conversion so resource IDs
# like "/subscriptions/<id>/..." are not rewritten before being passed to az.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

ENV_FILE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/config/poc.env}"
POLICY_DIR="$SCRIPT_DIR/../policy"
RULES_FILE="$POLICY_DIR/onboard-hybrid-worker.rules.json"
PARAMS_FILE="$POLICY_DIR/onboard-hybrid-worker.params.json"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file not found: $ENV_FILE"
    echo "Copy config/poc.env.template to config/poc.env and fill in the values."
    exit 1
fi
for f in "$RULES_FILE" "$PARAMS_FILE"; do
    [[ -f "$f" ]] || { echo "Error: policy file not found: $f"; exit 1; }
done

# shellcheck source=/dev/null
source "$ENV_FILE"

required=(SUBSCRIPTION_ID LOCATION AUTOMATION_RESOURCE_GROUP AUTOMATION_ACCOUNT_NAME)
for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

# Scope the policy to the resource group that holds the Arc-enabled IIS servers.
POLICY_SCOPE_RESOURCE_GROUP="${POLICY_SCOPE_RESOURCE_GROUP:-${ARC_RESOURCE_GROUP:-$AUTOMATION_RESOURCE_GROUP}}"
HYBRID_WORKER_GROUP="${HYBRID_WORKER_GROUP:-iis-servers}"
POLICY_NAME="deploy-iis-hybrid-worker"
POLICY_DISPLAY_NAME="Deploy Hybrid Worker extension to Arc IIS servers (IIS log relocation)"
ASSIGNMENT_NAME="deploy-iis-hybrid-worker"

az account set --subscription "$SUBSCRIPTION_ID"

# Register the providers this DeployIfNotExists policy touches.
for rp in Microsoft.PolicyInsights Microsoft.Automation Microsoft.HybridCompute; do
    state=$(az provider show --namespace "$rp" --subscription "$SUBSCRIPTION_ID" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$state" != "Registered" ]]; then
        echo "  Registering resource provider: $rp"
        az provider register --namespace "$rp" --subscription "$SUBSCRIPTION_ID" >/dev/null
    fi
done

SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${POLICY_SCOPE_RESOURCE_GROUP}"
AUTOMATION_RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${AUTOMATION_RESOURCE_GROUP}"

# --- Read the Automation Account's hybrid service URL ----------------------
ACCOUNT_ID="${AUTOMATION_RG_SCOPE}/providers/Microsoft.Automation/automationAccounts/${AUTOMATION_ACCOUNT_NAME}"
HYBRID_URL=$(az rest --method get \
    --url "https://management.azure.com${ACCOUNT_ID}?api-version=2023-11-01" \
    --query "properties.automationHybridServiceUrl" -o tsv | tr -d '\r')
if [[ -z "$HYBRID_URL" || "$HYBRID_URL" == "null" ]]; then
    echo "Error: could not read automationHybridServiceUrl for Automation Account '$AUTOMATION_ACCOUNT_NAME'."
    echo "Run iis-log-relocation/scripts/deploy-runbook.sh first to create the account."
    exit 1
fi

# --- Create / update the custom policy definition --------------------------
# The Windows az CLI cannot open a POSIX path (e.g. /c/Users/... or /mnt/c/...) for the
# "@<file>" argument expansion, so convert to native Windows paths when possible.
to_native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"
    elif command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"
    else printf '%s' "$1"; fi
}
RULES_FILE_NATIVE="$(to_native "$RULES_FILE")"
PARAMS_FILE_NATIVE="$(to_native "$PARAMS_FILE")"
echo "Creating policy definition: $POLICY_NAME"
az policy definition create \
    --name "$POLICY_NAME" \
    --display-name "$POLICY_DISPLAY_NAME" \
    --description "Installs the extension-based Hybrid Runbook Worker on Arc-enabled Windows servers and registers them into a Hybrid Worker group, so the IIS log relocation runbook can run on them." \
    --rules "@$RULES_FILE_NATIVE" \
    --params "@$PARAMS_FILE_NATIVE" \
    --mode "Indexed" \
    --subscription "$SUBSCRIPTION_ID" \
    --only-show-errors >/dev/null

POLICY_DEF_ID=$(az policy definition show --name "$POLICY_NAME" --subscription "$SUBSCRIPTION_ID" --query id -o tsv | tr -d '\r')

# --- Assign the policy with a system-assigned identity ---------------------
echo "Assigning policy at scope: $SCOPE"
az policy assignment create \
    --name "$ASSIGNMENT_NAME" \
    --display-name "$POLICY_DISPLAY_NAME" \
    --policy "$POLICY_DEF_ID" \
    --scope "$SCOPE" \
    --subscription "$SUBSCRIPTION_ID" \
    --mi-system-assigned \
    --location "$LOCATION" \
    --params "{\"automationAccountName\":{\"value\":\"${AUTOMATION_ACCOUNT_NAME}\"},\"automationAccountResourceGroup\":{\"value\":\"${AUTOMATION_RESOURCE_GROUP}\"},\"hybridWorkerGroupName\":{\"value\":\"${HYBRID_WORKER_GROUP}\"},\"automationHybridServiceUrl\":{\"value\":\"${HYBRID_URL}\"}}" \
    --only-show-errors >/dev/null

PRINCIPAL_ID=$(az policy assignment show \
    --name "$ASSIGNMENT_NAME" \
    --scope "$SCOPE" \
    --subscription "$SUBSCRIPTION_ID" \
    --query "identity.principalId" -o tsv | tr -d '\r')

# --- Grant the managed identity the roles the deployment needs -------------
# The DINE template (a) writes the Hybrid Worker extension on the Arc machines and
# (b) writes the worker-group registration into the Automation Account. So the MI needs:
#   * Azure Connected Machine Resource Administrator  -> on the Arc-machine scope
#   * Automation Contributor                          -> on the Automation Account RG
echo "Granting roles to the policy managed identity..."
az role assignment create \
    --role "Azure Connected Machine Resource Administrator" \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type "ServicePrincipal" \
    --scope "$SCOPE" \
    --subscription "$SUBSCRIPTION_ID" 2>/dev/null \
    && echo "  Granted 'Azure Connected Machine Resource Administrator' on $SCOPE" \
    || echo "  'Azure Connected Machine Resource Administrator' already assigned"

az role assignment create \
    --role "Automation Contributor" \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type "ServicePrincipal" \
    --scope "$AUTOMATION_RG_SCOPE" \
    --subscription "$SUBSCRIPTION_ID" 2>/dev/null \
    && echo "  Granted 'Automation Contributor' on $AUTOMATION_RG_SCOPE" \
    || echo "  'Automation Contributor' already assigned"

echo ""
echo "Policy assigned. New Arc-enabled Windows servers in '$POLICY_SCOPE_RESOURCE_GROUP' will be"
echo "onboarded to Hybrid Worker group '$HYBRID_WORKER_GROUP' automatically."
echo "To onboard servers that already exist, run:"
echo "  ./iis-log-relocation/scripts/remediate-hybrid-worker-policy.sh $ENV_FILE"
