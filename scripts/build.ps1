param(
  [string]$CName,
  [string]$Username,
  [string]$WorkDir,
  [string]$Image,
  [string]$Dockerfile,
  [string]$DockerfileDir,
  [string]$BuildUser,
  [string]$StampFile,
  [string]$DotfilesRepo,
  [Parameter(ValueFromRemainingArguments)]
  [string[]]$VolumeArgs
)

$ErrorActionPreference = 'Continue'

Write-Host ""
Write-Host ">>> [capsule] Stopping old container/image..." -ForegroundColor DarkGray
docker stop $CName 2>$null | Out-Null
docker rm   $CName 2>$null | Out-Null
docker rmi  $Image 2>$null | Out-Null

Write-Host ">>> [capsule] Building Docker image..." -ForegroundColor Cyan
docker build -f $Dockerfile --build-arg USERNAME=$BuildUser -t $Image $DockerfileDir
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host ">>> [capsule] BUILD FAILED. Fix the Dockerfile and press Ctrl+Shift+D to retry." -ForegroundColor Red
  return
}

if ($StampFile -ne "") {
  $mtime = (Get-Item $Dockerfile).LastWriteTimeUtc.Ticks
  Set-Content -Path $StampFile -Value $mtime -NoNewline
}

Write-Host ">>> [capsule] Starting container..." -ForegroundColor Cyan
$runArgs = @("run", "-d", "--name", $CName) + $VolumeArgs + @("--restart", "unless-stopped", $Image, "sleep", "infinity")
docker @runArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host ">>> [capsule] Failed to start container." -ForegroundColor Red
  return
}

Write-Host ">>> [capsule] Setting up user '$Username'..." -ForegroundColor Cyan
docker exec $CName /usr/local/bin/setup-user.sh $Username $DotfilesRepo

Write-Host ">>> [capsule] Connecting..." -ForegroundColor Green
docker exec -it -u $Username -w $WorkDir $CName zsh
