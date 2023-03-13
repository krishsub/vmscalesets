[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    $ResourceGroupName,
    [Parameter(Mandatory = $true)]
    $BlobContainerName,
    [Parameter(Mandatory = $true)]
    $ReleaseFolderName
)

<#
    Uses blue/green deployment topology for update of a workload running on
    Azure VMSS. Assumes one VMSS which is currently active ("active" prefix
    below) and one VMSS which is currently inactive ("inactive" prefix below).
    The active VMSS becomes inactive and the inactive VMSS becomes active
    after the execution of this script.
#>

$extensionName = "AppInstallExtension"
$warningPreference = "SilentlyContinue"

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
$autoScaleSettings = Get-AzAutoscaleSetting -ResourceGroupName $ResourceGroupName

# Find the autoscale which has zero instances = inactive
# Find the autoscale which has non-zero instances = active
foreach ($item in $autoScaleSettings) {
    $someResource = Get-AzResource -ResourceId $item.TargetResourceUri
    $someVmss = Get-AzVmss -ResourceGroupName $someResource.ResourceGroupName -VMScaleSetName $someResource.ResourceName 
    # sanity check; actual VMSS count should be zero <-- matches auto-scale 0 default
    if ($item.Profile[0].CapacityDefault -eq 0 -and $someVmss.Sku.Capacity -eq 0) {
        $inactiveAutoScaleProfile = $item
    }
    # actual VMSS count should be non-zero <-- matches auto-scale non-zero default
    if ($item.Profile[0].CapacityDefault -gt 0 -and $someVmss.Sku.Capacity -gt 0) {
        $activeAutoScaleProfile = $item
    }
}

# Ensure state of resource group is consistent for performing blue/green deployment
# Should be 2 profiles for CPU autoscale, a VMSS with non-zero instances, 
# a VMSS with zero instance and a single storage account.
if ($inactiveAutoScaleProfile -and $activeAutoScaleProfile -and $storageAccount -and $storageAccount.Count -eq 1) {
    # Get and save autoscale settings for both VMSS
    $activeCapacityMininum = $activeAutoScaleProfile.Profile[0].CapacityMinimum
    $activeCapacityDefault = $activeAutoScaleProfile.Profile[0].CapacityDefault
    $activeCapacityMaximum = $activeAutoScaleProfile.Profile[0].CapacityMaximum

    $inactiveCapacityMininum = $inactiveAutoScaleProfile.Profile[0].CapacityMinimum
    $inactiveCapacityDefault = $inactiveAutoScaleProfile.Profile[0].CapacityDefault
    $inactiveCapacityMaximum = $inactiveAutoScaleProfile.Profile[0].CapacityMaximum

    Write-Output "Removing autoscale settings during deployment"
    # Prevent auto-scale from doing anything till the new version is handling load
    Remove-AzAutoscaleSetting -ResourceGroupName $ResourceGroupName -Name $inactiveAutoScaleProfile.Name | Out-Null
    Remove-AzAutoscaleSetting -ResourceGroupName $ResourceGroupName -Name $activeAutoScaleProfile.Name | Out-Null
    Write-Output "Removed autoscale settings during deployment"

    # Get the VMSS associated with inactive autoscale
    $inactiveResource = Get-AzResource -ResourceId $inactiveAutoScaleProfile.TargetResourceUri
    $inactiveVmss = Get-AzVmss -ResourceGroupName $inactiveResource.ResourceGroupName -VMScaleSetName $inactiveResource.ResourceName

    # Get the VMSS associated with active autoscale
    $activeResource = Get-AzResource -ResourceId $activeAutoScaleProfile.TargetResourceUri
    $activeVmss = Get-AzVmss -ResourceGroupName $activeResource.ResourceGroupName -VMScaleSetName $activeResource.ResourceName      

    # We don't update an extension, we remove it and add it (assuming release folder will change)
    try {
        Write-Output "Removing extension from $($inactiveVmss.Name)"
        Remove-AzVmssExtension -VirtualMachineScaleSet $inactiveVmss -Name $extensionName | Out-Null
        $inactiveVmss | Update-AzVmss | Out-Null
        Write-Output "Removed extension from $($inactiveVmss.Name)"
    }
    catch {
        Write-Output "No extension found with name $extensionName, will continue"
    }
    # Files to downloaded to VMSS, note that when using folders, the file name should be qualified in "commandToExecute"
    $settings = @{
        "fileUris"         = (
            "$($storageAccount.PrimaryEndpoints.Blob)$BlobContainerName/install.ps1",
            "$($storageAccount.PrimaryEndpoints.Blob)$BlobContainerName/xyzazcopy.exe",
            "https://download.visualstudio.microsoft.com/download/pr/ff197e9e-44ac-40af-8ba7-267d92e9e4fa/d24439192bc549b42f9fcb71ecb005c0/dotnet-hosting-7.0.3-win.exe"
        );
        "commandToExecute" = "powershell -ExecutionPolicy Unrestricted -File install.ps1 $($storageAccount.PrimaryEndpoints.Blob)$BlobContainerName  $ReleaseFolderName"
    }

    $storageAccountKey = Get-AzStorageAccountKey -ResourceGroupName $storageAccount.ResourceGroupName -Name $storageAccount.StorageAccountName

    $protectedSettings = @{
        "storageAccountName" = $storageAccount.StorageAccountName; 
        "storageAccountKey"  = $storageAccountKey[0].Value
    };

    try {        
        # Scale-out new version to old version's capacity 
        Write-Output "Scaling-out $($inactiveVmss.Name) from 0 to $($activeVmss.Sku.Capacity)"
        $inactiveVmss.Sku.Capacity = $activeVmss.Sku.Capacity
        # below can throw an exception if the script extension failed
        $inactiveVmss | Update-AzVmss | Out-Null  
        Write-Output "Scale-out $($inactiveVmss.Name) completed"

        # Update inactive VMSS with the extension pointing to latest app version
        Write-Output "Adding extension to VMSS $($inactiveVmss.Name)"
        $inactiveVmss = Add-AzVmssExtension `
            -VirtualMachineScaleSet $inactiveVmss `
            -Name $extensionName `
            -Publisher "Microsoft.Compute"  `
            -Type "CustomScriptExtension" `
            -TypeHandlerVersion "1.9" `
            -Setting $settings `
            -ProtectedSetting $protectedSettings `
            -ProvisionAfterExtension @("IaaSAntimalware", "MicrosoftMonitoringAgent", "DependencyAgentWindows")
        $inactiveVmss | Update-AzVmss
        Write-Output "Added extension to VMSS $($inactiveVmss.Name)"
        
        # Scale in the active VMSS (old app version) to 0
        Write-Output "Scaling-in $($activeVmss.Name) from $($activeVmss.Sku.Capacity) to 0"
        $activeVmss.Sku.Capacity = 0
        $activeVmss | Update-AzVmss | Out-Null
        Write-Output "Scale-in $($activeVmss.Name) completed"

        # Swap autoscale profiles between active & inactive VMSS
        $inactiveAutoScaleProfile.Profile[0].CapacityMinimum = $activeCapacityMininum
        $inactiveAutoScaleProfile.Profile[0].CapacityDefault = $activeCapacityDefault
        $inactiveAutoScaleProfile.Profile[0].CapacityMaximum = $activeCapacityMaximum

        $activeAutoScaleProfile.Profile[0].CapacityMinimum = $inactiveCapacityMininum
        $activeAutoScaleProfile.Profile[0].CapacityDefault = $inactiveCapacityDefault
        $activeAutoScaleProfile.Profile[0].CapacityMaximum = $inactiveCapacityMaximum
        
        # Add the auto-scale settings back
        $inactiveAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
        $activeAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
        
        Write-Output "################## Done scale swap ##################"
    }
    catch {
        # Updating inactive VMSS threw an error, attempt rollback to old state
        Write-Error "################## Error - rolling back changes ##################"
        $inactiveVMsExtensionState = ($inactiveVmss | Get-AzVmssVM).Resources.ProvisioningState
        if ($inactiveVMsExtensionState -notcontains 'Succeeded') {
            Write-Output "################## Extension failure, rollback ##################"
            # Extension failed, remove it
            Remove-AzVmssExtension -VirtualMachineScaleSet $inactiveVmss -Name $extensionName | Update-AzVmss | Out-Null
            # set back the capacity to 0
            $inactiveVmss.Sku.Capacity = 0
            $inactiveVmss | Update-AzVmss | Out-Null

            $inactiveAutoScaleProfile.Profile[0].CapacityMinimum = $inactiveCapacityMininum
            $inactiveAutoScaleProfile.Profile[0].CapacityDefault = $inactiveCapacityDefault
            $inactiveAutoScaleProfile.Profile[0].CapacityMaximum = $inactiveCapacityMaximum

            $activeAutoScaleProfile.Profile[0].CapacityMinimum = $activeCapacityMininum
            $activeAutoScaleProfile.Profile[0].CapacityDefault = $activeCapacityDefault
            $activeAutoScaleProfile.Profile[0].CapacityMaximum = $activeCapacityMaximum

            $inactiveAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
            $activeAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
            Write-Output "################## Extension failure, rollback complete ##################"
        }
        else {
        
        }
    }
}
else {
    Write-Error "Blue/Green VMSS doesn't seem to be a consistent state that permits upgrading."
}

