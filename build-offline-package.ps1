# Version: 20260508
# build-offline-package.ps1
# One-click offline package builder
# - Prompt for TRANSLATOR_KEY / TRANSLATOR_ENDPOINT_URI
# - Preflight endpoint check
# - Auto-generate .env and download docker compose file
# - docker pull + docker save
# - docker compose up to download models/license
# - parse MODELS / TRANSLATORSYSTEMCONFIG
# - print MODELS / TRANSLATORSYSTEMCONFIG to console
# - generate run-disconnected-container-docker-compose.yaml (packaged; no extra console line)
# - package everything into tar.gz
# - print SHA256 for tar.gz + generate archive\SHA256SUMS.txt
# - auto-remove temporary .env
# - SUCCESS cleanup: remove image tar, run yaml, azure-ai-translator folder, docker containers/network, and docker image
# - Leaves only: archive\log-*.log, archive\package-*.tar.gz, archive\SHA256SUMS.txt
# - Clean console output: suppress docker compose "variable not set" warnings during cleanup

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

# ===========================
# Prompt for required inputs
# ===========================
Write-Host ""
Write-Host "Please input Azure AI Translator settings:"

$TRANSLATOR_KEY_SECURE = Read-Host "TRANSLATOR_KEY (will not be echoed)" -AsSecureString
$TRANSLATOR_ENDPOINT_URI = Read-Host "TRANSLATOR_ENDPOINT_URI (https://xxx.cognitiveservices.azure.com)"

$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TRANSLATOR_KEY_SECURE)
$TRANSLATOR_KEY = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)

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

# ===========================
# Auto-generate .env (required by compose)
# ===========================
$envPath = Join-Path $PWD ".env"
@"
TRANSLATOR_KEY=$TRANSLATOR_KEY
TRANSLATOR_ENDPOINT_URI=$TRANSLATOR_ENDPOINT_URI
"@ | Out-File -FilePath $envPath -Encoding ascii -Force
Write-Host "INFO: Temporary .env generated for docker compose"

# ===========================
# Config
# ===========================
$Image = "mcr.microsoft.com/azure-cognitive-services/translator/text-translation:latest"
$ComposeFile = Join-Path $PWD "download-models-docker-compose.generated.yaml"

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
$runComposeName = "run-disconnected-container-docker-compose.yaml"
$runComposePath = Join-Path $ArchiveDir $runComposeName

$pkgName = "package-azure-ai-translator-container-$timestamp.tar.gz"
$pkgPath = Join-Path $ArchiveDir $pkgName

$success = $false

try {
  # ===========================
  # Generate docker compose for model/license download
  # ===========================
@'
---
networks:
  adi-network:
    driver: bridge

services:
  # Azure AI Translator
  azure-ai-translator:
    container_name: azure-ai-translator
    image: mcr.microsoft.com/azure-cognitive-services/translator/text-translation:latest
    restart: no
    env_file: ".env"
    environment:
      # Azure AI Translator settings
      EULA: accept
      apikey: ${TRANSLATOR_KEY}
      billing: ${TRANSLATOR_ENDPOINT_URI}
      Languages: zh-Hant,en
      MODEL_PATH: /usr/local/models
      GENERATEHOTFIXTEMPLATE: "false"
      DOWNLOADLICENSE: "true"
      Mounts:License: "/license"
      CATEGORIES: ""
      MODSENVIRONMENT: ""
      MODELS: ""
      TRANSLATORSYSTEMCONFIG: ""
      # .Net Core settings
      Mounts:Output: /logs
      # Other settings
      MODELS_UPDATED: "true"
    volumes:
      - ./azure-ai-translator/models:/usr/local/models
      - ./azure-ai-translator/logs:/logs
      - ./azure-ai-translator/output:/output
      - ./azure-ai-translator/license:/license
    expose:
      - "5000"
    ports:
      - "5000:5000"
    networks:
      - adi-network
'@ | Out-File -FilePath $ComposeFile -Encoding utf8 -Force
  Write-Host "INFO: Temporary docker compose generated for model/license download"

  # ===========================
  # Prepare folders
  # ===========================
  Ensure-Dir $ModelsDir
  Ensure-Dir $LogsDir
  Ensure-Dir $LicenseDir
  Ensure-Dir $HotfixDir
  Ensure-Dir (Join-Path $WorkRoot "output")
  Ensure-Dir $ArchiveDir
  Write-Host "INFO: Folder structure prepared"

  # ===========================
  # Pull image & save tar
  # ===========================
  Write-Host "====================="
  Write-Host "STEP 1: Pull container image"
  Write-Host "====================="
  & docker pull $Image
  if ($LASTEXITCODE -ne 0) { Fail "docker pull failed" $LASTEXITCODE }

  Write-Host "====================="
  Write-Host "STEP 2: Save container image"
  Write-Host "====================="
  & docker save -o $imageTarName $Image
  if ($LASTEXITCODE -ne 0) { Fail "docker save failed" $LASTEXITCODE }
  Move-Item $imageTarName $ArchiveDir -Force

  # ===========================
  # docker compose up (download models / license)
  # ===========================
  Write-Host "====================="
  Write-Host "STEP 3: Download models & license"
  Write-Host "====================="

  $stdoutTmp = "$composeLogPath.stdout"
  $stderrTmp = "$composeLogPath.stderr"

  $p = Start-Process docker `
    -ArgumentList @("compose", "-f", $ComposeFile, "up") `
    -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $stdoutTmp `
    -RedirectStandardError  $stderrTmp

  Get-Content $stdoutTmp, $stderrTmp | Out-File $composeLogPath -Encoding utf8
  Remove-Item $stdoutTmp, $stderrTmp -ErrorAction SilentlyContinue

  if ($p.ExitCode -ne 0) {
    Fail "docker compose failed. See log: $composeLogPath"
  }

  # ===========================
  # Remove .env (security)
  # ===========================
  Remove-Item $envPath -ErrorAction SilentlyContinue
  Write-Host "INFO: Temporary .env removed"

  # ===========================
  # Parse MODELS / CONFIG from log (prefer docker run lines)
  # ===========================
  $modelsLine = Select-String -Path $composeLogPath -Pattern 'docker run.*-e MODELS=' | Select-Object -First 1
  $configLine = Select-String -Path $composeLogPath -Pattern 'docker run.*-e TRANSLATORSYSTEMCONFIG=' | Select-Object -First 1

  if (-not $modelsLine -or -not $configLine) {
    Fail "Failed to parse MODELS / TRANSLATORSYSTEMCONFIG from compose log. Check: $composeLogPath"
  }

  if (-not ($modelsLine.Line -match 'MODELS=([^\s]+)')) { Fail "MODELS parse failed" }
  $MODELS = $Matches[1]

  if (-not ($configLine.Line -match 'TRANSLATORSYSTEMCONFIG=([^\s]+)')) { Fail "TRANSLATORSYSTEMCONFIG parse failed" }
  $TRANSLATORSYSTEMCONFIG = $Matches[1]

  Write-Host ""
  Write-Host "========================================"
  Write-Host "OFFLINE RUNTIME PARAMETERS (IMPORTANT)"
  Write-Host "========================================"
  Write-Host "MODELS:"
  Write-Host "  $MODELS"
  Write-Host ""
  Write-Host "TRANSLATORSYSTEMCONFIG:"
  Write-Host "  $TRANSLATORSYSTEMCONFIG"
  Write-Host "========================================"

  # ===========================
  # Generate offline docker-compose (will be included in package)
  # ===========================
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

  # ===========================
  # Package tar.gz
  # ===========================
  Write-Host "====================="
  Write-Host "STEP 4: Package tar.gz"
  Write-Host "====================="

  $staging = Join-Path $PWD "staging_$timestamp"
  Ensure-Dir $staging

  Copy-Item -Recurse $ModelsDir  (Join-Path $staging "azure-ai-translator\models")
  Copy-Item -Recurse $LicenseDir (Join-Path $staging "azure-ai-translator\license")
  Ensure-Dir (Join-Path $staging "archive")
  Ensure-Dir (Join-Path $staging "compose_config\dotnet_translate\TranslateFiles")

  Copy-Item $runComposePath   (Join-Path $staging "archive\$runComposeName")
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

  $shaFile = Join-Path $ArchiveDir "SHA256SUMS.txt"
  $pkgFileName = [System.IO.Path]::GetFileName($pkgPath)

  "{0}  {1}" -f $h.Hash.ToLower(), $pkgFileName |
    Out-File -FilePath $shaFile -Encoding ascii -Force

  Write-Host "SHA256SUMS.txt generated:"
  Write-Host "  $shaFile"

  $success = $true
}
finally {
  # Always try to remove temporary .env (if compose failed early)
  Remove-Item $envPath -ErrorAction SilentlyContinue | Out-Null

  if ($success) {
    Write-Host ""
    Write-Host "====================="
    Write-Host "SUCCESS CLEANUP"
    Write-Host "====================="

    # docker compose parses variables even for "down".
    # Provide dummy env vars (process scope only) to prevent warnings like:
    # "The TRANSLATOR_KEY variable is not set. Defaulting to a blank string."
    $oldKey = $env:TRANSLATOR_KEY
    $oldBilling = $env:TRANSLATOR_ENDPOINT_URI
    $env:TRANSLATOR_KEY = "dummy"
    $env:TRANSLATOR_ENDPOINT_URI = "dummy"

    try {
      & docker compose -f $ComposeFile down --remove-orphans | Out-Null
    } finally {
      if ($null -eq $oldKey) { Remove-Item Env:TRANSLATOR_KEY -ErrorAction SilentlyContinue } else { $env:TRANSLATOR_KEY = $oldKey }
      if ($null -eq $oldBilling) { Remove-Item Env:TRANSLATOR_ENDPOINT_URI -ErrorAction SilentlyContinue } else { $env:TRANSLATOR_ENDPOINT_URI = $oldBilling }
    }

    # Remove docker image to keep system clean (allow rerun without manual deletion)
    & docker rmi $Image | Out-Null

    # Remove local artifacts already inside package
    Remove-Item $imageTarPath -ErrorAction SilentlyContinue
    Remove-Item $runComposePath -ErrorAction SilentlyContinue
    Remove-Item $ComposeFile -ErrorAction SilentlyContinue

    # Remove working folder
    Remove-Item $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Cleanup done. Remaining artifacts:"
    Write-Host "  - $composeLogPath"
    Write-Host "  - $pkgPath"
    Write-Host "  - $(Join-Path $ArchiveDir 'SHA256SUMS.txt')"
  }

  Remove-Item $ComposeFile -ErrorAction SilentlyContinue | Out-Null
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
