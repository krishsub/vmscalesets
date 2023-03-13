param($storageBlob, $releaseFolderName)

Start-Transcript

# Windows features
Install-WindowsFeature Web-Server -IncludeManagementTools

# Install .NET Core 5.x 
.\dotnet-hosting-7.0.3-win.exe /install /quiet /norestart /log dotnetlog.txt

# Delay 30 seconds for .NET Core install to finish
Start-Sleep -Seconds 30

# Restart IIS
net stop was /y
net start w3svc

# Delay 10 seconds
Start-Sleep -Seconds 10

# Reconfigure App Pool
Start-IISCommitDelay
$pool = Get-IISAppPool -Name DefaultAppPool
$pool.ManagedRuntimeVersion = ""
Stop-IISCommitDelay

# Delay 10 seconds
Start-Sleep -Seconds 10

Stop-WebAppPool DefaultAppPool
net stop was /y
net start w3svc
Start-WebAppPool DefaultAppPool

# Delay 10 seconds
Start-Sleep -Seconds 10

# Deploy the app
Stop-WebAppPool DefaultAppPool
.\azcopy login --identity
.\azcopy cp $storageBlob/$releaseFolderName/* C:\inetpub\wwwroot --recursive
Start-WebAppPool DefaultAppPool

# Delay 10 seconds
Start-Sleep -Seconds 10

# App Pool recycle after .NET Core App Deploy
# Restart-Computer -Force
Stop-WebAppPool DefaultAppPool
net stop was /y
net start w3svc
Start-WebAppPool DefaultAppPool

# Delay 10 seconds
Start-Sleep -Seconds 10

Stop-Transcript
