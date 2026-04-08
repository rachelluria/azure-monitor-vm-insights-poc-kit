@description('Location for the Data Collection Rule')
param location string = 'westus2'

@description('Name prefix for the Data Collection Rules')
param dcrNamePrefix string = 'vm-insights-ready'

@description('Resource ID of the Log Analytics workspace (for logs-based/classic experience)')
param workspaceResourceId string

@description('Resource ID of the Azure Monitor workspace (for metrics-based/new experience)')
param monitoringAccountResourceId string

// ============================================================
// DCR 1: Logs-based experience (classic) — Log Analytics
// ============================================================
resource dcrLogsBased 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${dcrNamePrefix}-dcr'
  location: location
  kind: 'Windows'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'VMInsightsPerfCounters'
          streams: [
            'Microsoft-InsightsMetrics'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\VmInsights\\DetailedMetrics'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspaceResourceId
          name: 'vmInsightworkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-InsightsMetrics'
        ]
        destinations: [
          'vmInsightworkspace'
        ]
      }
    ]
  }
}

// ============================================================
// DCR 2: Metrics-based experience (new) — Azure Monitor workspace
// ============================================================
resource dcrOtel 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: '${dcrNamePrefix}-otel-dcr'
  location: location
  properties: {
    dataSources: {
      performanceCountersOTel: [
        {
          name: 'OtelDataSource'
          streams: [
            'Microsoft-OtelPerfMetrics'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'system.filesystem.usage'
            'system.disk.io'
            'system.disk.operation_time'
            'system.disk.operations'
            'system.memory.usage'
            'system.network.io'
            'system.cpu.time'
            'system.network.dropped'
            'system.network.errors'
            'system.uptime'
          ]
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          accountResourceId: monitoringAccountResourceId
          name: 'MonitoringAccountDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-OtelPerfMetrics'
        ]
        destinations: [
          'MonitoringAccountDestination'
        ]
      }
    ]
  }
}

output dcrLogsBasedId string = dcrLogsBased.id
output dcrOtelId string = dcrOtel.id
