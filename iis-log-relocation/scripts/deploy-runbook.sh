#!/usr/bin/env bash
# Deploy the IIS Log Relocation runbook to an Azure Automation account, and optionally
# onboard an Azure Arc-enabled IIS server as an (extension-based) Hybrid Runbook Worker
# so the runbook executes ON the server.
#
# After this script runs, the customer just opens the Automation Account, selects the
# runbook, and clicks Start -> Run on: Hybrid Worker. No script editing required.
#
# Usage:
#   ./deploy-runbook.sh [env-file]
#   ./deploy-runbook.sh [env-file] --onboard-worker <arc-machine-name>
#   ./deploy-runbook.sh --onboard-worker WIN-CQJTSPAOP3P
#
# Options:
#   --onboard-worker <name>   Also create the Hybrid Worker group and install the Hybrid
#                             Worker extension on the named Arc-enabled machine.
#   --runbook-file <path>     Override the runbook .ps1 (default: the generated runbook).

set -euo pipefail

# Disable Git Bash / MSYS automatic POSIX-to-Windows path conversion so resource IDs
# like "/subscriptions/<id>/..." (e.g. --vm-resource-id) are not rewritten before az.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# Resolve paths relative to this script so it can be run from any directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_FILE="$REPO_ROOT/config/poc.env"
ONBOARD_MACHINE=""
RUNBOOK_FILE="$SCRIPT_DIR/../runbook/Relocate-IISLogs.runbook.ps1"

# --- Parse arguments --------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --onboard-worker) ONBOARD_MACHINE="${2:?--onboard-worker needs a machine name}"; shift 2;;
        --runbook-file)   RUNBOOK_FILE="${2:?--runbook-file needs a path}"; shift 2;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
        *) POSITIONAL+=("$1"); shift;;
    esac
done
[[ ${#POSITIONAL[@]} -ge 1 ]] && ENV_FILE="${POSITIONAL[0]}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file not found: $ENV_FILE"
    echo "Copy config/poc.env.template to config/poc.env and fill in the values."
    exit 1
fi
if [[ ! -f "$RUNBOOK_FILE" ]]; then
    echo "Error: Runbook file not found: $RUNBOOK_FILE"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# --- Validate required variables -------------------------------------------
required=(SUBSCRIPTION_ID LOCATION)
for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable '$var' is not set in $ENV_FILE."
        exit 1
    fi
done

AUTOMATION_RESOURCE_GROUP="${AUTOMATION_RESOURCE_GROUP:-${POLICY_SCOPE_RESOURCE_GROUP:-${LOG_ANALYTICS_RESOURCE_GROUP:-}}}"
AUTOMATION_ACCOUNT_NAME="${AUTOMATION_ACCOUNT_NAME:-iis-log-relocation-aa}"
RUNBOOK_NAME="${RUNBOOK_NAME:-Relocate-IISLogs}"
HYBRID_WORKER_GROUP="${HYBRID_WORKER_GROUP:-iis-servers}"
ARC_RESOURCE_GROUP="${ARC_RESOURCE_GROUP:-$AUTOMATION_RESOURCE_GROUP}"

if [[ -z "$AUTOMATION_RESOURCE_GROUP" ]]; then
    echo "Error: AUTOMATION_RESOURCE_GROUP must be set in $ENV_FILE."
    exit 1
fi

# --- Ensure the Automation CLI extension is present ------------------------
if ! az extension show --name automation &>/dev/null; then
    echo "Installing 'automation' az CLI extension..."
    az extension add --name automation --only-show-errors >/dev/null
fi

az account set --subscription "$SUBSCRIPTION_ID"

# --- Ensure the resource group exists --------------------------------------
if ! az group show --name "$AUTOMATION_RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
    echo "Creating resource group: $AUTOMATION_RESOURCE_GROUP ($LOCATION)"
    az group create --name "$AUTOMATION_RESOURCE_GROUP" --location "$LOCATION" \
        --subscription "$SUBSCRIPTION_ID" >/dev/null
fi

# --- Ensure the Automation Account exists ----------------------------------
if ! az automation account show \
        --resource-group "$AUTOMATION_RESOURCE_GROUP" \
        --name "$AUTOMATION_ACCOUNT_NAME" \
        --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
    echo "Creating Automation Account: $AUTOMATION_ACCOUNT_NAME"
    az automation account create \
        --resource-group "$AUTOMATION_RESOURCE_GROUP" \
        --name "$AUTOMATION_ACCOUNT_NAME" \
        --location "$LOCATION" \
        --subscription "$SUBSCRIPTION_ID" \
        --only-show-errors >/dev/null
else
    echo "Automation Account already exists: $AUTOMATION_ACCOUNT_NAME"
fi

# --- Import + publish the runbook ------------------------------------------
# PowerShell (5.1) runtime: the relocation logic targets Windows PowerShell on the server.
if ! az automation runbook show \
        --resource-group "$AUTOMATION_RESOURCE_GROUP" \
        --automation-account-name "$AUTOMATION_ACCOUNT_NAME" \
        --name "$RUNBOOK_NAME" \
        --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
    echo "Creating runbook: $RUNBOOK_NAME"
    az automation runbook create \
        --resource-group "$AUTOMATION_RESOURCE_GROUP" \
        --automation-account-name "$AUTOMATION_ACCOUNT_NAME" \
        --name "$RUNBOOK_NAME" \
        --type "PowerShell" \
        --location "$LOCATION" \
        --subscription "$SUBSCRIPTION_ID" \
        --only-show-errors >/dev/null
fi

echo "Uploading runbook content from: $RUNBOOK_FILE"
# The Windows az CLI cannot open a POSIX path (e.g. /c/Users/... or /mnt/c/...) for the
# "@<file>" content reference, so convert to a native Windows path when possible.
if command -v cygpath >/dev/null 2>&1; then
    RUNBOOK_FILE_NATIVE="$(cygpath -w "$RUNBOOK_FILE")"
elif command -v wslpath >/dev/null 2>&1; then
    RUNBOOK_FILE_NATIVE="$(wslpath -w "$RUNBOOK_FILE")"
else
    RUNBOOK_FILE_NATIVE="$RUNBOOK_FILE"
fi
az automation runbook replace-content \
    --resource-group "$AUTOMATION_RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT_NAME" \
    --name "$RUNBOOK_NAME" \
    --content "@$RUNBOOK_FILE_NATIVE" \
    --subscription "$SUBSCRIPTION_ID" \
    --only-show-errors >/dev/null

echo "Publishing runbook: $RUNBOOK_NAME"
az automation runbook publish \
    --resource-group "$AUTOMATION_RESOURCE_GROUP" \
    --automation-account-name "$AUTOMATION_ACCOUNT_NAME" \
    --name "$RUNBOOK_NAME" \
    --subscription "$SUBSCRIPTION_ID" \
    --only-show-errors >/dev/null

# --- Optional: onboard an Arc server as a Hybrid Runbook Worker -------------
if [[ -n "$ONBOARD_MACHINE" ]]; then
    echo
    echo "Onboarding Hybrid Runbook Worker for Arc machine: $ONBOARD_MACHINE"

    ACCOUNT_ID=$(az automation account show \
        --resource-group "$AUTOMATION_RESOURCE_GROUP" \
        --name "$AUTOMATION_ACCOUNT_NAME" \
        --subscription "$SUBSCRIPTION_ID" \
        --query id -o tsv | tr -d '\r')

    # The Hybrid Worker extension needs the account's hybrid service registration URL.
    HYBRID_URL=$(az rest --method get \
        --url "https://management.azure.com${ACCOUNT_ID}?api-version=2023-11-01" \
        --query "properties.automationHybridServiceUrl" -o tsv | tr -d '\r')
    if [[ -z "$HYBRID_URL" || "$HYBRID_URL" == "null" ]]; then
        echo "Error: could not read automationHybridServiceUrl from the Automation Account."
        exit 1
    fi

    # Ensure the Hybrid Worker group exists.
    if ! az automation hrwg show \
            --resource-group "$AUTOMATION_RESOURCE_GROUP" \
            --automation-account-name "$AUTOMATION_ACCOUNT_NAME" \
            --name "$HYBRID_WORKER_GROUP" \
            --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
        echo "Creating Hybrid Worker group: $HYBRID_WORKER_GROUP"
        az automation hrwg create \
            --resource-group "$AUTOMATION_RESOURCE_GROUP" \
            --automation-account-name "$AUTOMATION_ACCOUNT_NAME" \
            --name "$HYBRID_WORKER_GROUP" \
            --subscription "$SUBSCRIPTION_ID" \
            --only-show-errors >/dev/null
    fi

    # Resolve the Arc machine resource id.
    MACHINE_ID=$(az connectedmachine show \
        --name "$ONBOARD_MACHINE" \
        --resource-group "$ARC_RESOURCE_GROUP" \
        --subscription "$SUBSCRIPTION_ID" \
        --query id -o tsv | tr -d '\r')
    if [[ -z "$MACHINE_ID" ]]; then
        echo "Error: Arc machine '$ONBOARD_MACHINE' not found in resource group '$ARC_RESOURCE_GROUP'."
        exit 1
    fi

    # Register the machine as a worker in the group (idempotent on a fresh GUID).
    if command -v uuidgen &>/dev/null; then
        WORKER_ID=$(uuidgen)
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        WORKER_ID=$(cat /proc/sys/kernel/random/uuid)
    else
        WORKER_ID=$(python3 -c 'import uuid;print(uuid.uuid4())')
    fi
    echo "Registering worker in group '$HYBRID_WORKER_GROUP'..."
    az automation hrwg hrw create \
        --resource-group "$AUTOMATION_RESOURCE_GROUP" \
        --automation-account-name "$AUTOMATION_ACCOUNT_NAME" \
        --hybrid-runbook-worker-group-name "$HYBRID_WORKER_GROUP" \
        --hybrid-runbook-worker-id "$WORKER_ID" \
        --vm-resource-id "$MACHINE_ID" \
        --subscription "$SUBSCRIPTION_ID" \
        --only-show-errors >/dev/null || \
        echo "  (worker may already be registered - continuing)"

    # Install the extension-based Hybrid Worker on the Arc machine.
    echo "Installing Hybrid Worker extension on $ONBOARD_MACHINE (this can take a few minutes)..."
    az connectedmachine extension create \
        --machine-name "$ONBOARD_MACHINE" \
        --resource-group "$ARC_RESOURCE_GROUP" \
        --name "HybridWorkerExtension" \
        --location "$LOCATION" \
        --publisher "Microsoft.Azure.Automation.HybridWorker" \
        --type "HybridWorkerForWindows" \
        --type-handler-version "1.1" \
        --settings "{\"AutomationAccountURL\":\"$HYBRID_URL\"}" \
        --subscription "$SUBSCRIPTION_ID" \
        --only-show-errors >/dev/null

    echo "Hybrid Worker onboarding submitted for $ONBOARD_MACHINE."
fi

# --- Summary ----------------------------------------------------------------
ACCOUNT_RID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$AUTOMATION_RESOURCE_GROUP/providers/Microsoft.Automation/automationAccounts/$AUTOMATION_ACCOUNT_NAME"
echo
echo "Runbook published."
echo "  Automation Account : $AUTOMATION_ACCOUNT_NAME ($AUTOMATION_RESOURCE_GROUP)"
echo "  Runbook            : $RUNBOOK_NAME (PowerShell 5.1)"
if [[ -n "$ONBOARD_MACHINE" ]]; then
    echo "  Hybrid Worker      : $ONBOARD_MACHINE -> group '$HYBRID_WORKER_GROUP'"
fi
echo
echo "Run it ad-hoc:"
echo "  Portal: https://portal.azure.com/#@/resource${ACCOUNT_RID}/runbooks"
echo "  -> open '$RUNBOOK_NAME' -> Start -> Run on: Hybrid Worker -> pick '$HYBRID_WORKER_GROUP'."
echo "  Set parameter AuditOnly=true for a dry run."
echo
echo "Or start it from the CLI:"
echo "  az automation runbook start \\"
echo "    --resource-group $AUTOMATION_RESOURCE_GROUP \\"
echo "    --automation-account-name $AUTOMATION_ACCOUNT_NAME \\"
echo "    --name $RUNBOOK_NAME \\"
echo "    --run-on $HYBRID_WORKER_GROUP"
