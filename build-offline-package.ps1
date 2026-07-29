# Version: 20260729
# build-offline-package.ps1
# One-shot, resumable offline package builder for the Azure AI Translator
# container. PowerShell port of build-offline-package.sh - kept logically in
# sync with it; see that file's header for the full step-by-step rationale.
#
# Design goal: this script can be re-run any number of times (e.g. after the
# container's SAS token expires mid-download, or the process gets killed) and
# will always pick up where it left off. At the start of every step it checks
# real on-disk / docker state and skips work that is already done, instead of
# relying on a separate "progress" marker file.
#
# Steps:
#   0. Short-circuit: if a valid, hash-verified package already exists, stop here.
#   1. docker pull the container image (skipped if already present locally)
#   2. docker save -> archive\oci-azure-translator-text-translation.tar
#      (skipped if the tar already matches the currently loaded image ID)
#   3. docker compose up to download models + license. Auto-retries up to 15
#      times (SAS token is only valid 1 hour, models total ~3.2GB, so a slow
#      connection can outlast it); already-downloaded files are only
#      re-validated by the container, not re-downloaded, so interrupting or
#      rerunning is always safe.
#   4. Parse MODELS / TRANSLATORSYSTEMCONFIG from the container's own log,
#      generate the offline run-compose file, and tar.gz everything into a
#      self-contained delivery package + SHA256SUMS.txt.
#
# Deliberately NOT done after success: the script does not delete the docker
# image, the downloaded models/license, or the image tar. Keeping them is what
# makes reruns fast and makes the "already done, skip it" checks possible.
# Pass -Force to ignore all "already done" checks and rebuild everything.

param(
  [switch]$Force
)

$ErrorActionPreference = "Stop"
$scriptStartTime = Get-Date

Write-Host "========================================"
Write-Host ("Script started at : {0}" -f $scriptStartTime.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Host "========================================"

# ===========================
# Helper functions
# ===========================
function Ensure-Dir([string]$Path) {
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Fail([string]$Message, [int]$Code = 1) {
  $now = Get-Date
  $elapsed = $now - $scriptStartTime
  Write-Host "ERROR: $Message"
  Write-Host ("Elapsed time before failure: {0}" -f $elapsed.ToString("hh\:mm\:ss"))
  exit $Code
}

function Test-EndpointReachable([string]$Uri) {
  try {
    $u = [Uri]$Uri
    if ($u.Scheme -ne "https") {
      return @{ Ok = $false; Detail = "Endpoint must be https://" }
    }

    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.Method = "HEAD"
    $req.Timeout = 10000

    try {
      $resp = $req.GetResponse()
      $code = [int]$resp.StatusCode
      $resp.Close()
      return @{ Ok = $true; Detail = "Reachable (HTTP $code)" }
    } catch [System.Net.WebException] {
      if ($_.Exception.Response) {
        $code = [int]$_.Exception.Response.StatusCode
        return @{ Ok = $true; Detail = "Reachable (HTTP $code)" }
      }
      return @{ Ok = $false; Detail = $_.Exception.Message }
    }
  } catch {
    return @{ Ok = $false; Detail = $_.Exception.Message }
  }
}

# Prints the newest package path whose SHA256 matches SHA256SUMS.txt, or
# $null if none is valid. Also removes other stale/broken package files once
# a valid one has been confirmed, so only one delivery file remains.
function Find-ValidPackage {
  if (-not (Test-Path $shaFile)) { return $null }

  $packages = Get-ChildItem -Path $ArchiveDir -Filter "package-azure-ai-translator-container-*.tar.gz" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

  $best = $null
  foreach ($pkg in $packages) {
    $pattern = "  " + [regex]::Escape($pkg.Name) + '$'
    $line = Select-String -Path $shaFile -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (-not $line) { continue }
    $expected = ($line.Line -split '\s+')[0]
    $actual = (Get-FileHash -Path $pkg.FullName -Algorithm SHA256).Hash.ToLower()
    if ($expected -eq $actual) { $best = $pkg.FullName; break }
  }
  if (-not $best) { return $null }

  foreach ($pkg in $packages) {
    if ($pkg.FullName -ne $best) { Remove-Item $pkg.FullName -Force -ErrorAction SilentlyContinue }
  }
  return $best
}

# ===========================
# Config / paths
# ===========================
$Image = "mcr.microsoft.com/azure-cognitive-services/translator/text-translation:latest"
$ContainerName = "azure-ai-translator"

$WorkRoot   = Join-Path $PWD "azure-ai-translator"
$ModelsDir  = Join-Path $WorkRoot "models"
$LogsDir    = Join-Path $WorkRoot "logs"
$LicenseDir = Join-Path $WorkRoot "license"
$HotfixDir  = Join-Path $WorkRoot "hotfix"
$ArchiveDir = Join-Path $PWD "archive"

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$composeLog = "log-download-models_$timestamp.log"
$composeLogPath = Join-Path $ArchiveDir $composeLog

$imageTarName = "oci-azure-translator-text-translation.tar"
$imageTarPath = Join-Path $ArchiveDir $imageTarName
$imageTarIdPath = "${imageTarPath}.imageid"

$runComposeName = "run-disconnected-container-docker-compose.yaml"
$ComposeFile = Join-Path $PWD "download-models-docker-compose.generated.yaml"
$envPath = Join-Path $PWD ".env"
$shaFile = Join-Path $ArchiveDir "SHA256SUMS.txt"

$MaxDownloadAttempts = 15

Ensure-Dir $ArchiveDir

# ===========================
# STEP 0: short-circuit if a valid package already exists
# ===========================
if (-not $Force) {
  $existingPkg = Find-ValidPackage
  if ($existingPkg) {
    $pkgName = Split-Path $existingPkg -Leaf
    $pattern = "  " + [regex]::Escape($pkgName) + '$'
    $line = Select-String -Path $shaFile -Pattern $pattern | Select-Object -Last 1
    $hash = ($line.Line -split '\s+')[0]

    Write-Host ""
    Write-Host "========================================"
    Write-Host "ALREADY DONE - nothing to build"
    Write-Host "========================================"
    Write-Host "A valid delivery package already exists and its SHA256 matches"
    Write-Host "$shaFile, so there is nothing to (re)build."
    Write-Host ""
    Write-Host "  Package : $existingPkg"
    Write-Host "  SHA256  : $hash"
    Write-Host ""
    Write-Host "Deploy it using docs\Azure_translate_deploy-guide.md, or rerun with -Force to"
    Write-Host "rebuild from scratch."
    exit 0
  }
}

# ===========================
# Permission preflight (best effort, Linux/WSL pwsh only)
# ===========================
# Files the container previously created while running as its default
# non-root UID (65532) cannot be chmod'd by a normal host user - only root
# can. STEP 3 pins the container to the host UID/GID for all NEW downloads
# when running on Linux, so this class of problem cannot recur going forward;
# this preflight only best-effort-fixes leftovers from older runs.
$IsLinuxHost = (Get-Variable -Name IsLinux -Scope Global -ErrorAction SilentlyContinue) -and $IsLinux
if ($IsLinuxHost -and (Test-Path $WorkRoot)) {
  & chmod -R u+rwX,go+rwX $WorkRoot 2>$null
}

# ===========================
# Credentials
# ===========================
Write-Host ""
Write-Host "Please input Azure AI Translator settings:"

$TRANSLATOR_KEY = $env:TRANSLATOR_KEY
$TRANSLATOR_ENDPOINT_URI = $env:TRANSLATOR_ENDPOINT_URI

if ((-not $TRANSLATOR_KEY -or -not $TRANSLATOR_ENDPOINT_URI) -and (Test-Path $envPath)) {
  Write-Host "INFO: found existing .env in $PWD, reusing it"
  Get-Content $envPath | ForEach-Object {
    if ($_ -match '^\s*([^=\s]+)\s*=\s*(.*)$') {
      Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
    }
  }
  $TRANSLATOR_KEY = $env:TRANSLATOR_KEY
  $TRANSLATOR_ENDPOINT_URI = $env:TRANSLATOR_ENDPOINT_URI
}

if (-not $TRANSLATOR_KEY) {
  $TRANSLATOR_KEY_SECURE = Read-Host "TRANSLATOR_KEY (will not be echoed)" -AsSecureString
  $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TRANSLATOR_KEY_SECURE)
  $TRANSLATOR_KEY = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}
if (-not $TRANSLATOR_ENDPOINT_URI) {
  $TRANSLATOR_ENDPOINT_URI = Read-Host "TRANSLATOR_ENDPOINT_URI (https://xxx.cognitiveservices.azure.com)"
}

if ([string]::IsNullOrWhiteSpace($TRANSLATOR_KEY)) { Fail "TRANSLATOR_KEY is empty" }
if ([string]::IsNullOrWhiteSpace($TRANSLATOR_ENDPOINT_URI)) { Fail "TRANSLATOR_ENDPOINT_URI is empty" }

# ===========================
# Preflight check
# ===========================
Write-Host ""
Write-Host "====================="
Write-Host "PREFLIGHT CHECK"
Write-Host "====================="

$pre = Test-EndpointReachable $TRANSLATOR_ENDPOINT_URI
if (-not $pre.Ok) { Fail "Endpoint check failed: $($pre.Detail)" }
Write-Host ("Endpoint check: {0}" -f $pre.Detail)
Write-Host "Key provided: OK"

@"
TRANSLATOR_KEY=$TRANSLATOR_KEY
TRANSLATOR_ENDPOINT_URI=$TRANSLATOR_ENDPOINT_URI
"@ | Out-File -FilePath $envPath -Encoding ascii -Force
Write-Host "INFO: .env ready for docker compose"

Ensure-Dir $ModelsDir
Ensure-Dir $LogsDir
Ensure-Dir $LicenseDir
Ensure-Dir $HotfixDir
Ensure-Dir (Join-Path $WorkRoot "output")
Write-Host "INFO: Folder structure prepared"

$success = $false

try {
  # ===========================
  # STEP 1: pull image (skip if already present)
  # ===========================
  Write-Host ""
  Write-Host "====================="
  Write-Host "STEP 1: Pull container image"
  Write-Host "====================="

  & docker image inspect $Image *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "SKIP: image already present locally: $Image"
  } else {
    & docker pull $Image
    if ($LASTEXITCODE -ne 0) { Fail "docker pull failed" $LASTEXITCODE }
  }

  $currentImageId = (& docker image inspect $Image --format '{{.Id}}')

  # ===========================
  # STEP 2: save image tar (skip if it already matches the loaded image)
  # ===========================
  Write-Host ""
  Write-Host "====================="
  Write-Host "STEP 2: Save container image"
  Write-Host "====================="

  $tarUpToDate = $false
  if ((Test-Path $imageTarPath) -and (Test-Path $imageTarIdPath)) {
    $savedId = (Get-Content $imageTarIdPath -Raw).Trim()
    if ($savedId -eq $currentImageId.Trim()) { $tarUpToDate = $true }
  }

  if ($tarUpToDate) {
    Write-Host "SKIP: $imageTarPath already matches the current image ID"
  } else {
    & docker save -o $imageTarName $Image
    if ($LASTEXITCODE -ne 0) { Fail "docker save failed" $LASTEXITCODE }
    Move-Item $imageTarName $ArchiveDir -Force
    Set-Content -Path $imageTarIdPath -Value $currentImageId -NoNewline
  }

  # ===========================
  # STEP 3: download models & license (auto-retry on SAS expiry)
  # ===========================
  Write-Host ""
  Write-Host "====================="
  Write-Host "STEP 3: Download models & license"
  Write-Host "====================="

  $hostUser = $null
  if ($IsLinuxHost) {
    $hostUser = "$((& id -u).Trim()):$((& id -g).Trim())"
    Write-Host "INFO: pinning download container to host UID:GID $hostUser"
  }

  $composeLines = @(
    '---'
    'networks:'
    '  adi-network:'
    '    driver: bridge'
    ''
    'services:'
    '  azure-ai-translator:'
    "    container_name: $ContainerName"
    "    image: $Image"
    '    restart: no'
  )
  if ($hostUser) { $composeLines += "    user: `"$hostUser`"" }
  $composeLines += @(
    '    env_file: ".env"'
    '    environment:'
    '      EULA: accept'
    '      apikey: ${TRANSLATOR_KEY}'
    '      billing: ${TRANSLATOR_ENDPOINT_URI}'
    '      Languages: zh-Hant,en'
    '      MODEL_PATH: /usr/local/models'
    '      GENERATEHOTFIXTEMPLATE: "false"'
    '      DOWNLOADLICENSE: "true"'
    '      Mounts:License: "/license"'
    '      CATEGORIES: ""'
    '      MODSENVIRONMENT: ""'
    '      MODELS: ""'
    '      TRANSLATORSYSTEMCONFIG: ""'
    '      Mounts:Output: /logs'
    '      MODELS_UPDATED: "true"'
    '    volumes:'
    '      - ./azure-ai-translator/models:/usr/local/models'
    '      - ./azure-ai-translator/logs:/logs'
    '      - ./azure-ai-translator/output:/output'
    '      - ./azure-ai-translator/license:/license'
    '    expose:'
    '      - "5000"'
    '    networks:'
    '      - adi-network'
  )
  $composeLines -join "`n" | Out-File -FilePath $ComposeFile -Encoding utf8 -Force
  Write-Host "INFO: download compose generated"

  & docker rm -f $ContainerName 2>$null | Out-Null

  for ($attempt = 1; $attempt -le $MaxDownloadAttempts; $attempt++) {
    Write-Host ""
    Write-Host "--- Download attempt $attempt/$MaxDownloadAttempts ---"

    $attemptLog = "${composeLogPath}.attempt"
    Remove-Item $attemptLog -ErrorAction SilentlyContinue

    $stdoutTmp = "${composeLogPath}.stdout"
    $stderrTmp = "${composeLogPath}.stderr"

    $p = Start-Process docker `
      -ArgumentList @("compose", "-f", $ComposeFile, "up") `
      -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput $stdoutTmp `
      -RedirectStandardError  $stderrTmp

    Get-Content $stdoutTmp, $stderrTmp -ErrorAction SilentlyContinue | Out-File $attemptLog -Encoding utf8
    Remove-Item $stdoutTmp, $stderrTmp -ErrorAction SilentlyContinue

    & docker compose -f $ComposeFile down --remove-orphans 2>$null | Out-Null

    Get-Content $attemptLog -ErrorAction SilentlyContinue | Add-Content $composeLogPath -Encoding utf8

    # Exit code 0 = clean success. A non-zero exit that says "a valid license
    # has been found" is ALSO success: every model validated fine and the
    # only reason the container stopped is that DOWNLOADLICENSE=true refused
    # to re-fetch a license that is already present and valid.
    $validLicenseFound = Select-String -Path $attemptLog -Pattern 'a valid license has been found' -Quiet -ErrorAction SilentlyContinue

    if ($p.ExitCode -eq 0 -or $validLicenseFound) {
      Remove-Item $attemptLog -ErrorAction SilentlyContinue
      Write-Host "INFO: Download attempt $attempt completed successfully"
      break
    }

    Remove-Item $attemptLog -ErrorAction SilentlyContinue
    Write-Host "WARN: Attempt $attempt exited with code $($p.ExitCode) (likely SAS token expiry or transient network error)"

    if ($attempt -eq $MaxDownloadAttempts) {
      Write-Host "       Log tail (last 30 lines):"
      Get-Content $composeLogPath -Tail 30 -ErrorAction SilentlyContinue
      Fail "docker compose failed after $MaxDownloadAttempts attempts. See log: $composeLogPath. Just rerun this script - already-downloaded files are kept."
    }
    Write-Host "       Retrying (already-downloaded files are only re-validated, not re-downloaded)..."
  }

  Remove-Item $envPath -ErrorAction SilentlyContinue
  Write-Host "INFO: .env removed"

  # ===========================
  # Parse MODELS / CONFIG from log (last match wins, mirrors the bash script)
  # ===========================
  $modelsMatches = Select-String -Path $composeLogPath -Pattern '-e MODELS=(\S+)' -AllMatches -ErrorAction SilentlyContinue
  $configMatches = Select-String -Path $composeLogPath -Pattern '-e TRANSLATORSYSTEMCONFIG=(\S+)' -AllMatches -ErrorAction SilentlyContinue

  if (-not $modelsMatches -or -not $configMatches) {
    Fail "Failed to parse MODELS / TRANSLATORSYSTEMCONFIG from compose log. Check: $composeLogPath"
  }

  $MODELS = (($modelsMatches | Select-Object -Last 1).Matches | Select-Object -Last 1).Groups[1].Value
  $TRANSLATORSYSTEMCONFIG = (($configMatches | Select-Object -Last 1).Matches | Select-Object -Last 1).Groups[1].Value

  Write-Host ""
  Write-Host "========================================"
  Write-Host "OFFLINE RUNTIME PARAMETERS"
  Write-Host "========================================"
  Write-Host "MODELS:"
  Write-Host "  $MODELS"
  Write-Host ""
  Write-Host "TRANSLATORSYSTEMCONFIG:"
  Write-Host "  $TRANSLATORSYSTEMCONFIG"
  Write-Host "========================================"

  # ===========================
  # STEP 4: package everything
  # ===========================
  Write-Host ""
  Write-Host "====================="
  Write-Host "STEP 4: Package tar.gz"
  Write-Host "====================="

  $pkgName = "package-azure-ai-translator-container-$timestamp.tar.gz"
  $pkgPath = Join-Path $ArchiveDir $pkgName

  # run-disconnected-container-docker-compose.yaml is written at the package
  # ROOT, the same directory level as azure-ai-translator/, so docker compose
  # resolves the relative volume paths (./azure-ai-translator/...) without
  # needing a --project-directory workaround at deploy time.
  $staging = Join-Path $PWD "staging_$timestamp"
  Ensure-Dir $staging

  Copy-Item -Recurse $ModelsDir  (Join-Path $staging "azure-ai-translator\models")
  Copy-Item -Recurse $LicenseDir (Join-Path $staging "azure-ai-translator\license")
  Ensure-Dir (Join-Path $staging "azure-ai-translator\logs")
  Ensure-Dir (Join-Path $staging "azure-ai-translator\output")
  Ensure-Dir (Join-Path $staging "azure-ai-translator\hotfix")
  Ensure-Dir (Join-Path $staging "archive")
  Ensure-Dir (Join-Path $staging "compose_config\dotnet_translate\TranslateFiles")

  $runComposePath = Join-Path $staging $runComposeName
  @"
---
networks:
  adi-network:
    driver: bridge

services:
  azure-ai-translator:
    container_name: azure-ai-translator
    image: $Image
    restart: always
    environment:
      EULA: accept
      Languages: zh-Hant,en
      MODEL_PATH: /usr/local/models
      GENERATEHOTFIXTEMPLATE: "false"
      DOWNLOADLICENSE: "false"
      Mounts:License: "/license"
      MODELS: "$MODELS"
      TRANSLATORSYSTEMCONFIG: "$TRANSLATORSYSTEMCONFIG"
      Mounts:Output: /logs
      MODELS_UPDATED: "false"
      HotfixDataFolder: /user/local/customhotfix
      HotfixReloadInterval: "1"
      HotfixReloadEnabled: "true"
    volumes:
      - ./azure-ai-translator/models:/usr/local/models
      - ./azure-ai-translator/logs:/logs
      - ./azure-ai-translator/output:/output
      - ./azure-ai-translator/license:/license
      - ./azure-ai-translator/hotfix:/hotfix
      - ./compose_config/dotnet_translate/TranslateFiles:/user/local/customhotfix
    ports:
      - "5000:5000"
    networks:
      - adi-network
"@ | Out-File $runComposePath -Encoding utf8

  Copy-Item $imageTarPath     (Join-Path $staging "archive\$imageTarName")
  Copy-Item $composeLogPath   (Join-Path $staging "archive\$composeLog")

  Push-Location $staging
  tar -czf $pkgPath .
  Pop-Location

  Remove-Item $staging -Recurse -Force

  Write-Host "Delivery package created:"
  Write-Host "  $pkgPath"

  # ===========================
  # SHA256 hash (console) + SHA256SUMS.txt (for vendor)
  # ===========================
  $h = Get-FileHash -Path $pkgPath -Algorithm SHA256

  Write-Host ""
  Write-Host "========================================"
  Write-Host "DELIVERY FILE HASH (SHA256)"
  Write-Host "========================================"
  Write-Host ("File   : {0}" -f $pkgPath)
  Write-Host ("SHA256 : {0}" -f $h.Hash)
  Write-Host "========================================"

  "{0}  {1}" -f $h.Hash.ToLower(), $pkgName |
    Out-File -FilePath $shaFile -Encoding ascii -Append

  Write-Host "SHA256SUMS.txt updated: $shaFile"

  # Remove any older package files now that this run's package is the
  # confirmed-good one, so only a single unambiguous delivery file remains.
  Get-ChildItem -Path $ArchiveDir -Filter "package-azure-ai-translator-container-*.tar.gz" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $pkgPath } |
    Remove-Item -Force -ErrorAction SilentlyContinue

  $success = $true
}
finally {
  Remove-Item $envPath -ErrorAction SilentlyContinue | Out-Null
  Remove-Item $ComposeFile -ErrorAction SilentlyContinue | Out-Null

  if ($success) {
    Write-Host ""
    Write-Host "Kept locally (for fast reruns / local testing):"
    Write-Host "  - docker image  : $Image"
    Write-Host "  - models/license: $WorkRoot"
    Write-Host "  - image tar     : $imageTarPath"
  }
}

# ===========================
# Timing (end)
# ===========================
$scriptEndTime = Get-Date
$elapsed = $scriptEndTime - $scriptStartTime
Write-Host "========================================"
Write-Host ("Script finished at : {0}" -f $scriptEndTime.ToString("yyyy-MM-dd HH:mm:ss"))
Write-Host ("Elapsed time      : {0}" -f $elapsed.ToString("hh\:mm\:ss"))
Write-Host "========================================"
