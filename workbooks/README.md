# Workbooks

Azure Monitor Workbook templates that layer on top of the VM Insights / Azure Update Manager configuration deployed by this repo.

## server-patch-inventory-compliance.workbook.json

Operational dashboard for **Arc-enabled and Azure VM Windows servers**, built from the requirements captured in a customer call:

> "How many of these servers are 2016 vs 2019 vs 2022? Which ones aren't on the latest CU? Did they install **and** reboot, on time? Which patch group is falling behind, and who do I follow up with?"

### Tabs

| # | Tab | Answers |
|---|-----|---------|
| 1 | Overview | Total servers, compliant %, reboot-pending, OS mix, pending updates by classification |
| 2 | OS & Build Inventory | OS → Build → Server drill-down tree; build distribution per OS |
| 3 | CU Compliance | Per-server target build vs current; tag-driven **production n-1** rule |
| 4 | Reboot Compliance | Installed vs installed+rebooted; on-time within maintenance window |
| 5 | Patch Groups | Compliance % grouped by your existing patch group tag |
| 6 | Exceptions | Manual reboot list, 35-day delayed list, approved n-1 prod list |
| 7 | Data Health | Arc connection, Update Manager scan freshness, AMA extension state, LA heartbeats |
| 8 | SCCM Comparison | Live Azure compliance + placeholder for a joined SCCM custom-table query |

### Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `Subscriptions` | All | ARG cross-subscription scope |
| `ResourceGroups` | All | Filter to a subset of RGs |
| `PatchGroupTag` | `PatchGroup` | Tag mirroring your SCCM collection / patch group |
| `EnvironmentTag` | `Environment` | Tag used to detect production |
| `ProdTagValue` | `Production` | Value of the env tag that means prod (enables n-1 rule) |
| `WindowHours` | `4` | Maintenance window length for "on-time reboot" |
| `Lookback` | 30 days | Window for install/reboot history |

### Tagging convention (Environment / Prod)

`EnvironmentTag` and `ProdTagValue` are two halves of one rule:

- **`EnvironmentTag`** is the tag **key** to read on each server (default `Environment`).
- **`ProdTagValue`** is the tag **value** that means "this server is production" (default `Production`).

Together they tell the workbook: *"Look at the tag called **Environment**; treat any server whose value is **Production** as prod and apply the n‑1 allowance."*

Example resource tag:

| Key | Value |
|---|---|
| `Environment` | `Production` |

If your org tags differently, just change the two parameters once — no KQL edits:

| Your convention | `EnvironmentTag` | `ProdTagValue` |
|---|---|---|
| `Environment = Production` (default) | `Environment` | `Production` |
| `env = prod` | `env` | `prod` |
| `Tier = PROD` | `Tier` | `PROD` |

Apply the tag with the CLI:

```bash
az tag update --resource-id <vmOrArcResourceId> --operation merge --tags Environment=Production
```

Until at least one server carries the tag, the n‑1 rule never fires and every server must be on the latest observed build.

### Prerequisites

- **Arc-enabled servers** onboarded and reporting (`Microsoft.HybridCompute/machines`).
- **Azure Update Manager periodic assessment** enabled — populates `patchassessmentresources` and `patchinstallationresources` in Azure Resource Graph.
- **AMA + the DCRs from this repo** deployed (gives the Data Health tab a working `Heartbeat` signal).
- Optional but recommended: tag servers with `PatchGroup`, `Environment`, and `Owner`.

### Deploy options

**Option A — Import via the portal (fastest)**

1. Azure Portal → **Monitor** → **Workbooks** → **+ New** → ✏️ **Advanced Editor** → **Gallery Template (JSON)**.
2. Paste the contents of [server-patch-inventory-compliance.workbook.json](server-patch-inventory-compliance.workbook.json).
3. **Apply** → **Done Editing** → **Save** to a resource group.

**Option B — Deploy as an ARM workbook resource**

Wrap the JSON in a `Microsoft.Insights/workbooks` ARM/Bicep resource using the file contents as the `serializedData` property. Suggested follow-up: add a `bicep/workbook.bicep` template that does this and a `scripts/deploy-workbook.sh` to invoke it alongside the existing PoC scripts.

### Customising

- **Different OS coverage** — extend the `case(...)` branches that derive `OSVersion` if you have Windows Server 2025 / 2012 / non-standard images.
- **CU target source** — by default the workbook treats the **highest build observed in your estate** per OS as the target. To pin to a published CU build, replace the `targets` let with a hard-coded table.
- **SCCM join** — once SCCM compliance is shipped to Log Analytics (custom log, e.g. `SCCMCompliance_CL`), replace the placeholder block on tab 8 with a `union` against the Azure-side query and pivot by `Source`.
