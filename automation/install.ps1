param($storageBlob, $releaseFolderName)

$ErrorActionPreference = "Stop"

Start-Transcript

try {
    # Windows features
    Write-Output "Installing Windows Features..."
    Install-WindowsFeature Web-Server -IncludeManagementTools
    Write-Output "Finished installing Windows Features..."
}
catch {
    Stop-Transcript
    throw
}

try {
    # Install .NET Core 5.x 
    Write-Output "Installing .NET hosting Features..."
    .\dotnet-hosting-7.0.3-win.exe /install /quiet /norestart /log dotnetlog.txt
    Write-Output "Finished installing .NET hosting Features..."
}
catch {
    Stop-Transcript
    throw
}

try {
    # Delay 30 seconds for .NET Core install to finish
    Write-Output "Sleeping 30 seconds for .NET Core install to finish..."
    Start-Sleep -Seconds 30

    # Restart IIS
    Write-Output "Restart IIS"
    net stop was /y
    net start w3svc

    # Delay 10 seconds
    Write-Output "Sleeping 10 seconds for IIS to restart..."
    Start-Sleep -Seconds 10

    # Reconfigure App Pool
    Write-Output "Reconfiguring App Pool"
    Start-IISCommitDelay
    $pool = Get-IISAppPool -Name DefaultAppPool
    $pool.ManagedRuntimeVersion = ""
    Stop-IISCommitDelay
    Write-Output "Reconfigured App Pool"

    # Delay 10 seconds
    Write-Output "Sleeping 10 seconds for App Pool to restart..."
    Start-Sleep -Seconds 10

    Write-Output "Starting restart of IIS after AppPool reconfigure"
    Stop-WebAppPool DefaultAppPool
    net stop was /y
    net start w3svc
    Start-WebAppPool DefaultAppPool
    Write-Output "Completed restart of IIS after AppPool reconfigure"

    # Delay 10 seconds
    Start-Sleep -Seconds 10

    # Deploy the app
    Write-Output "Deploying app"
    Stop-WebAppPool DefaultAppPool
    .\azcopy login --identity
    .\azcopy cp $storageBlob/$releaseFolderName/* C:\inetpub\wwwroot --recursive
    Start-WebAppPool DefaultAppPool
    Write-Output "Deployed app"

    # Delay 10 seconds
    Start-Sleep -Seconds 10

    # App Pool recycle after .NET Core App Deploy
    # Restart-Computer -Force
    Write-Output "Restarting IIS after app deploy"
    Stop-WebAppPool DefaultAppPool
    net stop was /y
    net start w3svc
    Start-WebAppPool DefaultAppPool
    Write-Output "Restarted IIS after app deploy"

    # Delay 10 seconds
    Start-Sleep -Seconds 10

    Stop-Transcript
}
catch {
    Stop-Transcript
    throw
}
