@minLength(1)
@maxLength(10)
param scaleSetNamePrefix string
param location string = resourceGroup().location
param vmPrefix string = 'vm'
param vmSku string = 'Standard_D4ds_v4'
param imageSku string = '2022-Datacenter'
param adminUsername string = 'azureuser'
@secure()
param adminPassword string
param scaleSetDefaultVMCount int = 2
param scaleSetMaxVMCount int = 100
param scaleSetScaleByCount int = 2
param scaleSetScaleOutWhenCpuAbove int = 50
param scaleSetScaleInWhenCpuBelow int = 30
param vmCpuAlertThreshold int = 75
param vmFreeMemoryGBLessThanAlertThreshold int = 10
param deployBastion bool = true

var color = {
  blue: 'blue'
  green: 'green'
}

// array used for looping, can't loop over objects
var colorArray = [
  color.blue
  color.green
]

var scaleSetName = {
  blue: '${scaleSetNamePrefix}-${color.blue}'
  green: '${scaleSetNamePrefix}-${color.green}'
}

var vmName = {
  blue: '${vmPrefix}-${color.blue}'
  green: '${vmPrefix}-${color.green}'
}

var scaleSetMinVMCount = scaleSetDefaultVMCount // min & default are set the same
var vmFreeMemoryBytesLessThanAlertThreshold = vmFreeMemoryGBLessThanAlertThreshold * 1000 * 1000 * 1000

var nsgName = '${scaleSetNamePrefix}-nsg'
var vnetName = '${scaleSetNamePrefix}-vnet'

var lbName = '${scaleSetNamePrefix}-lb'
var lbFrontendIpConfigName = '${lbName}-frontipconfig'
var lbBackendPoolName = '${lbName}-backendpool'
var lbHealthProbeName = '${lbName}-healthprobe'
var lbHealthProbeReqPath = '/HealthCheck'
var lbRuleName = '${lbName}-rule'

var scaleSetIpConfigName = '${scaleSetNamePrefix}-ipconfig'
var scaleSetNetworkInterfaceConfigName = '${scaleSetNamePrefix}-nic'

var bastionPipName = '${scaleSetNamePrefix}-pip-bastion'
var bastionName = '${scaleSetNamePrefix}-bastion'

var logAnalyticsName = '${scaleSetNamePrefix}-loganalytics'

var natGatewayPipName = '${scaleSetNamePrefix}-pip-natgateway'
var natGatewayName = '${scaleSetNamePrefix}-natgateway'

var privateLinkString = 'privatelink'
var storageSuffixString = environment().suffixes.storage
var privateLinkBlobStorage = '${privateLinkString}.blob.${storageSuffixString}'
var storageAccountName = '${scaleSetNamePrefix}blobstoracc'
var storagePrivateLinkEndpointName = '${storageAccountName}-pvtendpt'
var privateDnsZoneNetworkLinkName = '${privateLinkString}-linkto-${vnetName}'
var storageBlobPrivateDnsZoneGroup = '${storagePrivateLinkEndpointName}-privatednszonegroup'

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-07-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'httpRule'
        properties: {
          description: 'Permit HTTP'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 101
          direction: 'Inbound'
        }
      }
      {
        name: 'applbRule'
        properties: {
          description: 'Permit App Gateway Ranges'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 102
          direction: 'Inbound'
        }
      }
      {
        name: 'azureMonitorRule'
        properties: {
          description: 'Permit Azure Monitor Ranges'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMonitor'
          destinationPortRange: '*'
          access: 'Allow'
          priority: 101
          direction: 'Outbound'
        }
      }
      {
        name: 'guestAndHybridManagementRule'
        properties: {
          description: 'Permit Azure Automation Ranges'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'GuestAndHybridManagement'
          destinationPortRange: '*'
          access: 'Allow'
          priority: 102
          direction: 'Outbound'
        }
      }
      {
        name: 'storageRule'
        properties: {
          description: 'Permit Azure Storage Ranges'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '*'
          access: 'Allow'
          priority: 103
          direction: 'Outbound'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.0.0/27'
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: 'LbSubnet'
        properties: {
          addressPrefix: '10.0.0.32/27'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: 'AppSubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          natGateway: {
            id: natGateway.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource loadBalancer 'Microsoft.Network/loadBalancers@2022-07-01' = {
  name: lbName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: lbFrontendIpConfigName
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: virtualNetwork.properties.subnets[1].id
          }
          privateIPAddressVersion: 'IPv4'
        }
        zones: [
          '1'
          '2'
          '3'
        ]
      }
    ]
    backendAddressPools: [
      {
        name: lbBackendPoolName
      }
    ]
    probes: [
      {
        name: lbHealthProbeName
        properties: {
          port: 80
          protocol: 'Http'
          intervalInSeconds: 5
          numberOfProbes: 5
          requestPath: lbHealthProbeReqPath
        }
      }
    ]
    loadBalancingRules: [
      {
        name: lbRuleName
        properties: {
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, lbFrontendIpConfigName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, lbHealthProbeName)
          }
        }
      }
    ]
  }
}

resource vmArray 'Microsoft.Compute/virtualMachines@2022-11-01' = [for (colorItem, index) in colorArray: {
  name: vmName[colorItem]
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSku
    }
    osProfile: {
      computerName: vmName[colorItem]
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        offer: 'WindowsServer'
        publisher: 'MicrosoftWindowsServer'
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNetworkInterfaceArray[index].id
        }
      ]
    }
  }
}]

resource vmNetworkInterfaceArray 'Microsoft.Network/networkInterfaces@2022-07-01' = [for (colorItem, index) in colorArray: {
  name: '${vmName[colorItem]}-nic'
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: '${vmName[colorItem]}-nic-ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: virtualNetwork.properties.subnets[2].id
          }
        }
      }
    ]
  }
}]

resource scaleSetArray 'Microsoft.Compute/virtualMachineScaleSets@2022-11-01' = [for (colorItem, index) in colorArray: {
  name: scaleSetName[colorItem]
  location: location
  sku: {
    name: vmSku
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    overprovision: false
    singlePlacementGroup: false
    upgradePolicy: {
      mode: 'Automatic'
    }
    virtualMachineProfile: {
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: scaleSetNetworkInterfaceConfigName
            properties: {
              enableAcceleratedNetworking: true
              primary: true
              ipConfigurations: [
                {
                  name: scaleSetIpConfigName
                  properties: {
                    loadBalancerBackendAddressPools: [
                      {
                        id: loadBalancer.properties.backendAddressPools[0].id
                      }
                    ]
                    subnet: {
                      id: virtualNetwork.properties.subnets[2].id
                    }
                  }
                }
              ]
            }
          }
        ]
      }
      osProfile: {
        adminUsername: adminUsername
        adminPassword: adminPassword
        computerNamePrefix: colorItem
      }
      storageProfile: {
        imageReference: {
          offer: 'WindowsServer'
          publisher: 'MicrosoftWindowsServer'
          sku: imageSku
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
        }
      }
      scheduledEventsProfile: {
        terminateNotificationProfile: {
          enable: true
          notBeforeTimeout: 'PT5M'
        }
      }
      extensionProfile: {
        extensions: [
          {
            name: 'IaaSAntimalware'
            properties: {
              publisher: 'Microsoft.Azure.Security'
              type: 'IaaSAntimalware'
              typeHandlerVersion: '1.7'
              autoUpgradeMinorVersion: true
              settings: {
                AntimalwareEnabled: true
                RealtimeProtectionEnabled: true
                ScheduledScanSettings: {
                  isEnabled: true
                  scanType: 'Quick'
                  day: 2 // Monday (0-daily, 1-Sunday, 2-Monday, ...., 7-Saturday, 8-Disabled)
                  time: 120 // 0-1440 (measured in minutes after midnight - 60->1AM, 120 -> 2AM, ... )
                }
              }
            }
          }
          {
            name: 'AzureMonitorWindowsAgent'
            properties: {
              publisher: 'Microsoft.Azure.Monitor'
              type: 'AzureMonitorWindowsAgent'
              typeHandlerVersion: '1.9'
              enableAutomaticUpgrade: true
              provisionAfterExtensions: [
                'IaaSAntimalware'
              ]
            }
          }
          {
            name: 'DependencyAgentWindows'
            properties: {
              publisher: 'Microsoft.Azure.Monitoring.DependencyAgent'
              type: 'DependencyAgentWindows'
              typeHandlerVersion: '9.9'
              enableAutomaticUpgrade: true
              provisionAfterExtensions: [
                'AzureMonitorWindowsAgent'
              ]
            }
          }
        ]
      }
    }
  }
}]

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: bastionPipName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2022-07-01' = if (deployBastion) {
  name: bastionName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          publicIPAddress: {
            id: bastionPublicIp.id
          }
          subnet: {
            id: virtualNetwork.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource natGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: natGatewayPipName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2022-07-01' = {
  name: natGatewayName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natGatewayPublicIp.id
      }
    ]
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource vmInsightsSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'VMInsights(${logAnalyticsName})'
  location: location
  properties: {
    workspaceResourceId: logAnalytics.id
  }
  plan: {
    name: 'VMInsights(${logAnalyticsName})'
    product: 'OMSGallery/VMInsights'
    promotionCode: ''
    publisher: 'Microsoft'
  }
}

resource blobStorage 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Premium_ZRS'
  }
  kind: 'BlockBlobStorage'
  properties: {
    networkAcls: {
      defaultAction: 'Deny'
    }
  }
}

@description('This is the built-in Storage Blob Data Contributor role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#storage-blob-data-contributor')
resource storageBlobDataContributorRoleDef 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

@description('This is the built-in Reader role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#reader')
resource readerRoleDef 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
}

resource scaleSetToBlobDataContributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (colorItem, index) in colorArray: {
  name: guid(resourceGroup().id, scaleSetArray[index].id, blobStorage.id, storageBlobDataContributorRoleDef.id)
  scope: blobStorage
  properties: {
    principalId: scaleSetArray[index].identity.principalId
    roleDefinitionId: storageBlobDataContributorRoleDef.id
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    scaleSetArray
  ]
}]

resource scaleSetToStorageReaderAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (colorItem, index) in colorArray: {
  name: guid(resourceGroup().id, scaleSetArray[index].id, blobStorage.id, readerRoleDef.id)
  scope: blobStorage
  properties: {
    principalId: scaleSetArray[index].identity.principalId
    roleDefinitionId: readerRoleDef.id
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    scaleSetArray
  ]
}]

resource vmToBlobDataContributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (colorItem, index) in colorArray: {
  name: guid(resourceGroup().id, vmArray[index].id, blobStorage.id, storageBlobDataContributorRoleDef.id)
  scope: blobStorage
  properties: {
    principalId: vmArray[index].identity.principalId
    roleDefinitionId: storageBlobDataContributorRoleDef.id
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    vmArray
  ]
}]

resource vmToStorageReaderAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (colorItem, index) in colorArray: {
  name: guid(resourceGroup().id, vmArray[index].id, blobStorage.id, readerRoleDef.id)
  scope: blobStorage
  properties: {
    principalId: vmArray[index].identity.principalId
    roleDefinitionId: readerRoleDef.id
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    vmArray
  ]
}]

resource blobCorePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateLinkBlobStorage
  location: 'global'
  resource privateDnsZoneNetworkLink 'virtualNetworkLinks' = {
    name: privateDnsZoneNetworkLinkName
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: virtualNetwork.id
      }
    }
  }
}

resource blobStoragePrivateEndpoint 'Microsoft.Network/privateEndpoints@2022-07-01' = {
  name: storagePrivateLinkEndpointName
  location: location
  properties: {
    subnet: {
      id: virtualNetwork.properties.subnets[2].id
    }
    privateLinkServiceConnections: [
      {
        name: storagePrivateLinkEndpointName
        properties: {
          privateLinkServiceId: blobStorage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
  resource privateDnsZoneGroups 'privateDnsZoneGroups' = {
    name: storageBlobPrivateDnsZoneGroup
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'dnsConfig'
          properties: {
            privateDnsZoneId: blobCorePrivateDnsZone.id
          }
        }
      ]
    }
  }
}

resource cpuBasedAutoscaleArray 'Microsoft.Insights/autoscalesettings@2022-10-01' = [for (colorItem, index) in colorArray: {
  name: colorItem == color.blue ? 'cpuBasedAutoScale-${scaleSetName.blue}' : 'cpuBasedAutoScale-${scaleSetName.green}'
  location: location
  properties: {
    enabled: true
    targetResourceUri: scaleSetArray[index].id
    profiles: [
      {
        name: 'cpuProfile'
        rules: [
          {
            scaleAction: {
              cooldown: 'PT5M'
              direction: 'Increase'
              type: 'ChangeCount'
              value: '${scaleSetScaleByCount}'
            }
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: scaleSetArray[index].id
              operator: 'GreaterThanOrEqual'
              statistic: 'Average'
              threshold: scaleSetScaleOutWhenCpuAbove
              timeAggregation: 'Average'
              timeGrain: 'PT1M'
              timeWindow: 'PT5M'
            }
          }
          {
            scaleAction: {
              cooldown: 'PT5M'
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '${scaleSetScaleByCount}'
            }
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: scaleSetArray[index].id
              operator: 'LessThanOrEqual'
              statistic: 'Average'
              threshold: scaleSetScaleInWhenCpuBelow
              timeAggregation: 'Average'
              timeGrain: 'PT1M'
              timeWindow: 'PT5M'
            }
          }
        ]
        capacity: {
          default: colorItem == color.blue ? '${scaleSetDefaultVMCount}' : '0'
          maximum: '${scaleSetMaxVMCount}'
          minimum: colorItem == color.blue ? '${scaleSetMinVMCount}' : '0'
        }
      }
    ]
  }
}]

resource cpuMetricAlertsArray 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (colorItem, index) in colorArray: {
  name: 'cpuMetricAlerts-${scaleSetName[colorItem]}'
  location: 'global'
  properties: {
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'cpuThresholdAlert'
          threshold: vmCpuAlertThreshold
          metricName: 'Percentage CPU'
          timeAggregation: 'Average'
          operator: 'GreaterThanOrEqual'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            // per instance in VMSS instead of across instances 
            {
              name: 'VMName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
        }
      ]
    }
    enabled: true
    evaluationFrequency: 'PT1M'
    scopes: [
      scaleSetArray[index].id
    ]
    severity: 2 // 2 = Warning
    windowSize: 'PT15M' // CPU over vmCpuAlertThreshold for more than 15 minutes
  }
}]

resource memoryMetricAlertsArray 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (colorItem, index) in colorArray: {
  name: colorItem == color.blue ? 'memoryMetricAlerts-${scaleSetName.blue}' : 'memoryMetricAlerts-${scaleSetName.green}'
  location: 'global'
  properties: {
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'freeMemThresholdAlert'
          threshold: vmFreeMemoryBytesLessThanAlertThreshold
          metricName: 'Available Memory Bytes'
          timeAggregation: 'Average'
          operator: 'LessThanOrEqual'
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'VMName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
        }
      ]
    }
    enabled: true
    evaluationFrequency: 'PT1M'
    scopes: [
      scaleSetArray[index].id
    ]
    severity: 2 // 2 = Warning
    windowSize: 'PT5M' // 5 mins of memory pressure 
  }
}]

output mi1 string = scaleSetArray[0].identity.principalId
output mi2 string = scaleSetArray[1].identity.principalId
output xxxx string = storageBlobDataContributorRoleDef.id
