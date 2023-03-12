[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $resourceGroupName,
    $location = "West Europe"
)

New-AzResourceGroup -Name $resourceGroupName -Location $location -Force
