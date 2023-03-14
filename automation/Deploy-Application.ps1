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
    Azure VMSS. Uses "current" and "vNext" to indicate what is current and
    what will be the next version of the workload. 
#>

$extensionName = "AppInstallExtension"
$warningPreference = "SilentlyContinue"

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
$autoScaleSettings = Get-AzAutoscaleSetting -ResourceGroupName $ResourceGroupName

# Find the autoscale which has non-zero instances = current (version)
# Find the autoscale which has zero instances =vNext (version)
foreach ($item in $autoScaleSettings) {
    $someResource = Get-AzResource -ResourceId $item.TargetResourceUri
    $someVmss = Get-AzVmss -ResourceGroupName $someResource.ResourceGroupName -VMScaleSetName $someResource.ResourceName 
    # sanity check; actual VMSS count should be zero for "vNext"
    if ($item.Profile[0].CapacityDefault -eq 0 -and $someVmss.Sku.Capacity -eq 0) {
        $vNextAutoScaleProfile = $item
    }
    # actual VMSS count should be non-zero for "current"
    if ($item.Profile[0].CapacityDefault -gt 0 -and $someVmss.Sku.Capacity -gt 0) {
        $currentAutoScaleProfile = $item
    }
}

# Ensure state of resource group is consistent for performing blue/green deployment
# Should be 2 profiles for CPU autoscale, a VMSS with non-zero instances, 
# a VMSS with zero instance and a single storage account.
if ($currentAutoScaleProfile -and $vNextAutoScaleProfile -and $storageAccount -and $storageAccount.Count -eq 1) {
    # Get and save autoscale settings for both VMSS
    $vNextCapacityMininum = $vNextAutoScaleProfile.Profile[0].CapacityMinimum
    $vNextCapacityDefault = $vNextAutoScaleProfile.Profile[0].CapacityDefault
    $vNextCapacityMaximum = $vNextAutoScaleProfile.Profile[0].CapacityMaximum

    $currentCapacityMininum = $currentAutoScaleProfile.Profile[0].CapacityMinimum
    $currentCapacityDefault = $currentAutoScaleProfile.Profile[0].CapacityDefault
    $currentCapacityMaximum = $currentAutoScaleProfile.Profile[0].CapacityMaximum

    # Get the VMSS associated with "current" autoscale
    $currentVmssResource = Get-AzResource -ResourceId $currentAutoScaleProfile.TargetResourceUri
    $currentVmss = Get-AzVmss -ResourceGroupName $currentVmssResource.ResourceGroupName -VMScaleSetName $currentVmssResource.ResourceName
    $currentCapacity = $currentVmss.Sku.Capacity
    Write-Output "'Current': $($currentVmss.Name), capacity: $currentCapacity"

    # Get the VMSS associated with "vNext" autoscale
    $vNextVmssResource = Get-AzResource -ResourceId $vNextAutoScaleProfile.TargetResourceUri
    $vNextVmss = Get-AzVmss -ResourceGroupName $vNextVmssResource.ResourceGroupName -VMScaleSetName $vNextVmssResource.ResourceName
    Write-Output "'vNext': $($vNextVmss.Name)"

    # Prevent auto-scale from doing anything till "vNext" is handling load, so remove it
    Write-Output "Removing autoscale settings during deployment"
    Remove-AzAutoscaleSetting -ResourceGroupName $ResourceGroupName -Name $currentAutoScaleProfile.Name | Out-Null
    Remove-AzAutoscaleSetting -ResourceGroupName $ResourceGroupName -Name $vNextAutoScaleProfile.Name | Out-Null
    Write-Output "Removed autoscale settings during deployment"

    # Ensure "vNext" is clean without an extension
    try {
        Write-Output "Removing extension: $extensionName from 'vNext': $($vNextVmss.Name)"
        Remove-AzVmssExtension -VirtualMachineScaleSet $vNextVmss -Name $extensionName | Out-Null
        Write-Output "Removed extension: $extensionName from 'vNext': $($vNextVmss.Name), updating VMSS"
        $vNextVmss | Update-AzVmss | Out-Null
    }
    catch {
        Write-Output "No extension: $extensionName from 'vNext': $($vNextVmss.Name) to remove, will continue"
    }
    
    # Files to downloaded to VMSS, note that when using folders, the file name should be qualified in "commandToExecute"
    $settings = @{
        "fileUris"         = (
            "$($storageAccount.PrimaryEndpoints.Blob)$BlobContainerName/install.ps1",
            "$($storageAccount.PrimaryEndpoints.Blob)$BlobContainerName/azcopy.exe",
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
        # Scale-out "vNext" to "current" capacity 
        Write-Output "Scaling-out 'vNext': $($vNextVmss.Name) from 0 to $currentCapacity"
        $vNextVmss.Sku.Capacity = $currentCapacity
        $vNextVmss | Update-AzVmss | Out-Null  
        Write-Output "Scaling-out 'vNext': $($vNextVmss.Name) from 0 to $currentCapacity complete"

        # Update "vNext" VMSS with the extension pointing to latest app version
        Write-Output "Adding extension to 'vNext': $($vNextVmss.Name)"
        $vNextVmss = Add-AzVmssExtension `
            -VirtualMachineScaleSet $vNextVmss `
            -Name $extensionName `
            -Publisher "Microsoft.Compute"  `
            -Type "CustomScriptExtension" `
            -TypeHandlerVersion "1.9" `
            -Setting $settings `
            -ProtectedSetting $protectedSettings `
            -ProvisionAfterExtension @("IaaSAntimalware", "AzureMonitorWindowsAgent", "DependencyAgentWindows")
        $vNextVmss | Update-AzVmss | Out-Null
        Write-Output "Added extension: $extensionName to 'vNext': $($vNextVmss.Name)"
        
        # Scale in "current" to 0
        Write-Output "Scaling-in 'current': $($currentVmss.Name) from $($currentVmss.Sku.Capacity) to 0"
        $currentVmss.Sku.Capacity = 0
        $currentVmss | Update-AzVmss | Out-Null
        Write-Output "Scale-in 'current': $($currentVmss.Name) completed to 0"

        # Swap autoscale profiles between "current" & "vNext" VMSS
        $currentAutoScaleProfile.Profile[0].CapacityMinimum = $vNextCapacityMininum
        $currentAutoScaleProfile.Profile[0].CapacityDefault = $vNextCapacityDefault
        $currentAutoScaleProfile.Profile[0].CapacityMaximum = $vNextCapacityMaximum

        $vNextAutoScaleProfile.Profile[0].CapacityMinimum = $currentCapacityMininum
        $vNextAutoScaleProfile.Profile[0].CapacityDefault = $currentCapacityDefault
        $vNextAutoScaleProfile.Profile[0].CapacityMaximum = $currentCapacityMaximum
        
        # Add the auto-scale settings back which we removed earlier
        Write-Output "Adding autoscale settings back"
        $currentAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
        $vNextAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
        Write-Output "Added autoscale settings back"
        
        Write-Output "################## Done vNext update ##################"
    }
    catch {
        Write-Output "################## Exception ##################"
        Write-Output $_.Exception
        Write-Output "################## Exception ##################"
        # "vNext" VMSS threw an error, attempt rollback to old state
        # Wrap individual actions in try / catch to ensure we attempt to rollback as much as possible
        Write-Output "################## Error, attempting rollback ##################"
        
        $vNextExtensionStates = ($vNextVmss | Get-AzVmssVM).Resources.ProvisioningState
        # Check if one of the extensions failed
        if ($vNextExtensionStates -contains 'Failed') {
            Write-Output "Removing extension: $extensionName from 'vNext': $($vNextVmss.Name)"
            try {
                # Extension failed, remove it
                Remove-AzVmssExtension -VirtualMachineScaleSet $vNextVmss -Name $extensionName | Update-AzVmss | Out-Null
            }
            catch {
                Write-Output "Couldn't remove extension: $extensionName from 'vNext': $($vNextVmss.Name)"
            }

            try {
                # set back the capacity to the original value
                $currentVmss.Sku.Capacity = $currentCapacity
                Write-Output "Reverting 'current': $($currentVmss.Name) to capacity: $currentCapacity"
                $currentVmss | Update-AzVmss | Out-Null
                Write-Output "Reverted 'current': $($currentVmss.Name) to capacity: $currentCapacity"
            }
            catch {
                Write-Output "Failed to revert 'current': $($currentVmss.Name) to capacity: $currentCapacity"
            }
            
            try {
                # set back the capacity to 0
                $vNextVmss.Sku.Capacity = 0
                Write-Output "Reverting 'vNext': $($vNextVmss.Name) to capacity: 0"
                $vNextVmss | Update-AzVmss | Out-Null
                Write-Output "Reverted 'vNext': $($vNextVmss.Name) to capacity: 0"
            }
            catch {
                Write-Output "Failed to revert 'vNext': $($vNextVmss.Name) to capacity: 0"
            }

            # set back the autoscale settings
            $currentAutoScaleProfile.Profile[0].CapacityMinimum = $currentCapacityMininum
            $currentAutoScaleProfile.Profile[0].CapacityDefault = $currentCapacityDefault
            $currentAutoScaleProfile.Profile[0].CapacityMaximum = $currentCapacityMaximum

            $vNextAutoScaleProfile.Profile[0].CapacityMinimum = $vNextCapacityMininum
            $vNextAutoScaleProfile.Profile[0].CapacityDefault = $vNextCapacityDefault
            $vNextAutoScaleProfile.Profile[0].CapacityMaximum = $vNextCapacityMaximum

            try {
                Write-Output "Adding back autoscale for 'current': $($currentVmss.Name)"
                $currentAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
                Write-Output "Added back autoscale for 'current': $($currentVmss.Name)"
            }
            catch {
                Write-Output "Failed to add back autoscale for 'current': $($currentVmss.Name)"
            }

            try {
                Write-Output "Adding back autoscale for 'vNext': $($vNextVmss.Name)"
                $vNextAutoScaleProfile | New-AzAutoscaleSetting | Out-Null
                Write-Output "Added back autoscale for 'vNext': $($vNextVmss.Name)"
            } 
            catch {
                Write-Output "Failed to add back autoscale for 'vNext': $($vNextVmss.Name)"
            }
            Write-Output "################## Rollback complete, check state ##################"
        }
        else {
            # None of the extensions seem to have failed? Yet, an error?
            Write-Output "################## No rollback action possible, unknown error, check state ##################"
        }
    }
}
else {
    Write-Error "Blue/Green VMSS doesn't seem to be a consistent state that permits upgrading."
}

