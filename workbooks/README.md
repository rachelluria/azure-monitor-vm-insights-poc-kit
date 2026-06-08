# Workbooks

Azure Monitor Workbook templates that layer on top of the VM Insights / Azure Update Manager configuration deployed by this repo.

## server-patch-inventory-compliance.workbook.json

Operational dashboard for **Arc-enabled and Azure VM Windows servers**, built from the requirements captured in a customer call:

> "How many of these servers are 2016 vs 2019 vs 2022? Which ones aren't on the latest CU? Did they install **and** reboot, on time? Which patch group is falling behind, and who do I follow up with?"

### Tabs

| # | Tab | Answers |
|---|-----|---------|
| 1 | Overview | Total servers, compliant %, reboot-pending, OS mix, pending updates by classification |
| 2 | OS & Build Inventory | Per-OS server count tiles, Arc vs Azure VM split, OS → Build → Server drill-down tree, build distribution per OS |
| 3 | CU Compliance | Per-server target build vs current, build distribution per OS with target marked, servers grouped by how many revisions behind, flags any pending Critical/Security/UpdateRollups |
| 4 | Failures | Run-level failures with Update Manager error code/message, per-patch (KB) failures, top failing KBs |
| 5 | Pending Updates | What's queued: per-server counts, top KBs across the estate, classification mix, recently published KBs |
| 6 | Reboot Compliance | Installed vs installed+rebooted; on-time within maintenance window |
| 7 | Patch Groups | Compliance % grouped by your existing patch group tag |
| 8 | Data Health | Arc connection, Update Manager scan freshness, AMA extension state, LA heartbeats |

### Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `Subscriptions` | All | ARG cross-subscription scope |
| `ResourceGroups` | All | Filter to a subset of RGs |
| `PatchGroupTag` | `PatchGroup` | Tag mirroring your SCCM collection / patch group |
| `WindowHours` | `4` | Maintenance window length for "on-time reboot" |
| `Lookback` | 30 days | Window for install/reboot history |
| `TargetBuilds` | _empty_ | Optional CU pin: `'Windows Server 2022','10.0.20348.2700','Windows Server 2019','10.0.17763.6189'`. Empty = auto-derive from estate. |

### Prerequisites

- **Arc-enabled servers** onboarded and reporting (`Microsoft.HybridCompute/machines`).
- **Azure Update Manager periodic assessment** enabled — populates `patchassessmentresources` and `patchinstallationresources` in Azure Resource Graph.
- **AMA + the DCRs from this repo** deployed (gives the Data Health tab a working `Heartbeat` signal).
- Optional but recommended: tag servers with `PatchGroup` and `Owner`.

### Deploy options

**Option A — Import via the portal (fastest)**

1. Azure Portal → **Monitor** → **Workbooks** → **+ New** → ✏️ **Advanced Editor** → **Gallery Template (JSON)**.
2. Paste the contents of [server-patch-inventory-compliance.workbook.json](server-patch-inventory-compliance.workbook.json).
3. **Apply** → **Done Editing** → **Save** to a resource group.

**Option B — Deploy as an ARM workbook resource**

Wrap the JSON in a `Microsoft.Insights/workbooks` ARM/Bicep resource using the file contents as the `serializedData` property. Suggested follow-up: add a `bicep/workbook.bicep` template that does this and a `scripts/deploy-workbook.sh` to invoke it alongside the existing PoC scripts.

### Customising

- **Different OS coverage** — extend the `case(...)` branches that derive `OSVersion` if you have Windows Server 2025 / 2012 / non-standard images.
- **CU target source** — by default the workbook treats the **highest build observed in your estate** per OS as the target (column `TargetSource = estate`). To pin to Microsoft's published build, fill in the **Target builds (override)** parameter on the CU Compliance tab — those OSes will then show `TargetSource = override`. There is no ARG/Update Manager field that exposes Microsoft's current published CU build per OS, so this override is the supported way to stay in sync with the AUM release cycle.
