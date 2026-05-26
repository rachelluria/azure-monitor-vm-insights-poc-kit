param(
  [string]$Sub = "e2e2bc9b-68b2-4e73-b07c-0413c85d1d2f",
  [string]$Rg  = "azure-arc",
  [string]$Location = "westus2",
  [string]$DisplayName = "Server Patch & Inventory Compliance",
  [string]$WorkbookFile = "workbooks/server-patch-inventory-compliance.workbook.json"
)
$ErrorActionPreference = "Stop"

$md5 = [System.Security.Cryptography.MD5]::Create()
$bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($DisplayName))
$hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
$wbGuid = "$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
Write-Host "Workbook GUID: $wbGuid"

$serialized = Get-Content -Raw $WorkbookFile

$template = @{
  '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
  contentVersion = '1.0.0.0'
  parameters = @{
    workbookName        = @{ type = 'string' }
    workbookDisplayName = @{ type = 'string' }
    workbookSerialized  = @{ type = 'string' }
    location            = @{ type = 'string' }
  }
  resources = @(
    @{
      type       = 'Microsoft.Insights/workbooks'
      apiVersion = '2022-04-01'
      name       = "[parameters('workbookName')]"
      location   = "[parameters('location')]"
      kind       = 'shared'
      properties = @{
        displayName    = "[parameters('workbookDisplayName')]"
        serializedData = "[parameters('workbookSerialized')]"
        version        = '1.0'
        sourceId       = 'azure monitor'
        category       = 'workbook'
      }
    }
  )
}
$params = @{
  '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  contentVersion = '1.0.0.0'
  parameters = @{
    workbookName        = @{ value = $wbGuid }
    workbookDisplayName = @{ value = $DisplayName }
    workbookSerialized  = @{ value = $serialized }
    location            = @{ value = $Location }
  }
}

$tpl = Join-Path $PWD 'wb-template.json'
$par = Join-Path $PWD 'wb-params.json'
$template | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $tpl
$params   | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $par

$deployName = "workbook-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
try {
  az deployment group create `
    --name $deployName `
    --resource-group $Rg `
    --subscription $Sub `
    --template-file $tpl `
    --parameters "@$par" `
    --output table
} finally {
  Remove-Item $tpl, $par -Force -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "Open in portal:"
Write-Host "https://portal.azure.com/#@/resource/subscriptions/$Sub/resourceGroups/$Rg/providers/Microsoft.Insights/workbooks/$wbGuid"
