# Azure AI Translator Offline Package Builder

本 repo 提供 `build-offline-package.ps1`，用於在有網路的 Windows 11 + Docker Desktop 環境中下載 Azure AI Translator container image、models、license，並打包成可帶到離線環境執行的交付檔。

目前 script 產出的 package 只包含繁體中文與英文所需模型，語言參數為 `zh-Hant,en`。

## 目錄

1. [Docker Desktop 安裝指南 Windows 11 + WSL2](#1-docker-desktop-安裝指南-windows-11--wsl2)
2. [執行 build-offline-package.ps1](#2-執行-build-offline-packageps1)
3. [Windows 離線執行下載好的 Docker image](#3-windows-離線執行下載好的-docker-image)
4. [Windows 更新既有離線伺服器上的 image 與 models](#4-windows-更新既有離線伺服器上的-image-與-models)
5. [Linux 離線執行下載好的 Docker image](#5-linux-離線執行下載好的-docker-image)
6. [Linux 更新既有離線伺服器上的 image 與 models](#6-linux-更新既有離線伺服器上的-image-與-models)
7. [參考文件](#7-參考文件)

---

# 1. Docker Desktop 安裝指南 Windows 11 + WSL2

## 1.1 系統需求

Docker Desktop 在 Windows 11 上建議使用 WSL 2 backend。WSL 2 是 Docker Desktop 在 Windows 上執行 Linux containers 的主要後端之一，Docker Desktop 會透過 WSL 2 提供 Linux kernel、檔案系統整合與 container runtime。

基本需求：

- Windows 11 64-bit，建議 Enterprise / Pro / Education。
- WSL 2 已安裝並啟用。
- BIOS / UEFI 已開啟 hardware virtualization。
- CPU 支援 Second Level Address Translation，通常現代 Intel / AMD CPU 皆支援。
- RAM 至少 8GB，實務上建議 16GB 以上。
- Docker Desktop 不支援 Windows Server 作為 Docker Desktop 執行環境。
- 企業商業使用需確認 Docker Desktop 授權條款。

檢查 Windows 版本：

```powershell
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsHardwareAbstractionLayer
```

檢查系統是否為 64-bit：

```powershell
[Environment]::Is64BitOperatingSystem
```

檢查 RAM：

```powershell
[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
```

檢查 virtualization 狀態：

```powershell
Get-CimInstance Win32_Processor |
  Select-Object Name, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions
```

若 `VirtualizationFirmwareEnabled` 為 `False`，請進 BIOS / UEFI 啟用 Intel VT-x 或 AMD-V。

---

## 1.2 安裝 WSL2 必要前置

請使用系統管理員 PowerShell 執行本節指令。

開啟系統管理員 PowerShell：

```powershell
Start-Process powershell -Verb RunAs
```

### 方法 A 建議

使用 Microsoft 建議的一行式安裝：

```powershell
wsl --install
```

安裝完成後重新開機：

```powershell
Restart-Computer
```

重新開機後確認 WSL 狀態：

```powershell
wsl --status
```

設定 WSL 預設版本為 2：

```powershell
wsl --set-default-version 2
```

更新 WSL：

```powershell
wsl --update
```

### 方法 B 手動

若企業映像檔、GPO 或 Windows Update 狀態導致 `wsl --install` 無法完成，可改用手動方式啟用 Windows features。

啟用 Windows Subsystem for Linux：

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
```

啟用 Virtual Machine Platform：

```powershell
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

重新開機：

```powershell
Restart-Computer
```

重新開機後設定 WSL 預設版本為 2：

```powershell
wsl --set-default-version 2
```

確認 WSL 狀態：

```powershell
wsl --status
```

WSL2 是 Docker Desktop 使用 WSL backend 的必要條件；若 WSL 沒有啟用，Docker Desktop 可能無法啟動 Linux containers。

---

## 1.3 安裝 Linux 發行版 建議 Ubuntu

安裝 Ubuntu：

```powershell
wsl --install -d Ubuntu
```

第一次啟動 Ubuntu：

```powershell
wsl -d Ubuntu
```

第一次啟動時，Ubuntu 會要求建立 Linux 使用者名稱與密碼。這組帳號密碼是 WSL 內部使用，和 Windows 帳號密碼不同。

確認 Ubuntu 使用 WSL 2：

```powershell
wsl -l -v
```

預期輸出中，Ubuntu 的 `VERSION` 應為 `2`：

```text
  NAME      STATE           VERSION
* Ubuntu    Running         2
```

若 Ubuntu 是 WSL 1，請轉換成 WSL 2：

```powershell
wsl --set-version Ubuntu 2
```

---

## 1.4 安裝 Docker Desktop

下載 Docker Desktop 官方安裝程式：

```powershell
$installer = Join-Path $env:TEMP "Docker Desktop Installer.exe"
Invoke-WebRequest `
  -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" `
  -OutFile $installer
```

執行安裝程式，需要系統管理員權限：

```powershell
Start-Process -FilePath $installer -Verb RunAs -Wait
```

安裝精靈中請確認：

- 勾選 `Use WSL 2 instead of Hyper-V` 或等效的 WSL 2 backend 選項。
- 若安裝程式要求登出、重新開機或啟用 Windows feature，請照指示完成。

完成後重新開機：

```powershell
Restart-Computer
```

---

## 1.5 啟動與設定 Docker Desktop

啟動 Docker Desktop：

```powershell
Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
```

啟動後進入 Docker Desktop UI：

1. `Settings` → `General`
2. 勾選 `Use WSL 2 based engine`
3. `Settings` → `Resources` → `WSL Integration`
4. 啟用 `Ubuntu`
5. 按 `Apply & Restart`

確認 Docker Desktop 背後的 WSL distributions：

```powershell
wsl -l -v
```

常見會看到：

```text
docker-desktop
docker-desktop-data
Ubuntu
```

---

## 1.6 驗證安裝

確認 Docker client / server：

```powershell
docker version
```

確認 Docker daemon 可執行 container：

```powershell
docker run hello-world
```

確認 WSL distribution 版本：

```powershell
wsl -l -v
```

預期結果：

- `docker version` 能看到 Client 與 Server。
- `docker run hello-world` 顯示成功訊息。
- `wsl -l -v` 中 Ubuntu 的 `VERSION` 為 `2`。

---

## 1.7 常見問題排除

### 問題 1 Docker Desktop 安裝失敗 權限錯誤

可能錯誤：

```text
C:\ProgramData\DockerDesktop ownership
Access denied
```

請使用系統管理員 PowerShell 修復 ownership 與 ACL：

```powershell
takeown /f "C:\ProgramData\DockerDesktop" /r /d y
```

```powershell
icacls "C:\ProgramData\DockerDesktop" /grant Administrators:F /t
```

修復後重新執行 Docker Desktop installer：

```powershell
Start-Process -FilePath $installer -Verb RunAs -Wait
```

### 問題 2 WSL 沒有啟用

症狀：

```text
WSL 2 installation is incomplete
The Windows Subsystem for Linux optional component is not enabled
```

解法：

```powershell
wsl --install
```

重新開機：

```powershell
Restart-Computer
```

### 問題 3 WSL version 不是 2

確認目前版本：

```powershell
wsl -l -v
```

設定新發行版預設為 WSL 2：

```powershell
wsl --set-default-version 2
```

將既有 Ubuntu 轉成 WSL 2：

```powershell
wsl --set-version Ubuntu 2
```

### 問題 4 docker command 無法使用

症狀：

```text
docker: The term 'docker' is not recognized
Cannot connect to the Docker daemon
```

確認 Docker Desktop 是否啟動：

```powershell
Get-Process "Docker Desktop" -ErrorAction SilentlyContinue
```

若未啟動：

```powershell
Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
```

確認 Docker daemon：

```powershell
docker info
```

若使用 WSL 內部執行 docker，請確認 WSL integration 已啟用：

```powershell
wsl -l -v
```

然後到 Docker Desktop：

```text
Settings -> Resources -> WSL Integration -> Enable Ubuntu
```

### 問題 5 docker pull 失敗

企業環境常見原因：

- Proxy 未設定。
- Firewall 阻擋 Docker registry。
- SSL inspection 造成憑證問題。

測試 registry 連線：

```powershell
Test-NetConnection registry-1.docker.io -Port 443
```

測試 Microsoft Container Registry：

```powershell
Test-NetConnection mcr.microsoft.com -Port 443
```

測試 pull：

```powershell
docker pull hello-world
```

若企業需要 proxy，請到 Docker Desktop：

```text
Settings -> Resources -> Proxies
```

設定後重新啟動 Docker Desktop：

```powershell
wsl --shutdown
Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
```

---

## 1.8 企業環境注意事項

- Docker Desktop 商業使用需符合 Docker 授權條款；大型企業或高營收組織通常需要付費訂閱。
- Docker Desktop 不支援 Windows Server；Windows Server 應使用對應的 container runtime 與 Microsoft 文件流程。
- Proxy / Firewall / SSL inspection 可能影響 `docker pull`。
- 建議 IT 預先確認 `mcr.microsoft.com`、`registry-1.docker.io`、Docker Desktop 更新服務等網路連線。
- 若企業採用 EDR / DLP / AppLocker，需確認 Docker Desktop、WSL、Hyper-V 相關元件未被阻擋。
- 建議統一 Docker Desktop 版本，避免不同工程師產出內容不一致。

---

## 1.9 最終確認 checklist

- [ ] Windows 11 64-bit。
- [ ] BIOS / UEFI virtualization 已啟用。
- [ ] WSL2 已啟用。
- [ ] Ubuntu 已安裝。
- [ ] Ubuntu 的 WSL `VERSION` 為 `2`。
- [ ] Docker Desktop 已安裝。
- [ ] Docker Desktop 已啟動。
- [ ] Docker Desktop 已啟用 WSL 2 based engine。
- [ ] Docker Desktop 已啟用 Ubuntu WSL Integration。
- [ ] `docker version` OK。
- [ ] `docker run hello-world` OK。

---

# 2. 執行 build-offline-package.ps1

## 2.1 執行目的

`build-offline-package.ps1` 會在有網路的機器上完成下列工作：

1. 要求輸入 `TRANSLATOR_KEY`。
2. 要求輸入 `TRANSLATOR_ENDPOINT_URI`。
3. 自動產生暫時 `.env`。
4. 自動產生暫時 `download-models-docker-compose.generated.yaml`。
5. Pull Azure AI Translator container image。
6. `docker save` 產生 image tar。
7. 使用 Docker Compose 下載 models 與 license。
8. 從 compose log 解析 `MODELS` 與 `TRANSLATORSYSTEMCONFIG`。
9. 產生離線用 `run-disconnected-container-docker-compose.yaml`。
10. 打包成 `archive\package-azure-ai-translator-container-<timestamp>.tar.gz`。
11. 產生 `archive\SHA256SUMS.txt`。
12. 成功後清理暫存 `.env`、下載用 compose、工作目錄與本機 image tar。

## 2.2 語言模型範圍

目前 script 內建的 Docker Compose 語言參數為：

```yaml
Languages: zh-Hant,en
```

因此打包流程只會下載繁體中文與英文所需模型，產出的 `run-disconnected-container-docker-compose.yaml` 也會使用相同語言參數。

## 2.3 User-managed glossary / hotfix 路徑

產出的 `run-disconnected-container-docker-compose.yaml` 會預留 user-managed glossary / hotfix 掛載路徑：

```yaml
environment:
  HotfixDataFolder: /user/local/customhotfix
  HotfixReloadInterval: "1"
  HotfixReloadEnabled: "true"

volumes:
  - ./compose_config/dotnet_translate/TranslateFiles:/user/local/customhotfix
```

請特別留意：`./compose_config/dotnet_translate/TranslateFiles` 是 container host 端的相對路徑，會依照離線執行時的 `--project-directory .` 所在目錄解析。

例如 Windows release 目錄為：

```text
C:\AzureAITranslatorOffline\releases\20260505_150000
```

則實際 host 路徑會是：

```text
C:\AzureAITranslatorOffline\releases\20260505_150000\compose_config\dotnet_translate\TranslateFiles
```

例如 Linux release 目錄為：

```text
/opt/azure-ai-translator-offline/releases/20260505_150000
```

則實際 host 路徑會是：

```text
/opt/azure-ai-translator-offline/releases/20260505_150000/compose_config/dotnet_translate/TranslateFiles
```

若客戶環境需要使用不同實體路徑，請在離線啟動前修改 `archive\run-disconnected-container-docker-compose.yaml` 或 `archive/run-disconnected-container-docker-compose.yaml` 中的 volume host path，並確認 container 內的 `HotfixDataFolder` 與 volume target path 一致。

## 2.4 Docker Compose network 設定

產出的 `run-disconnected-container-docker-compose.yaml` 預設使用 Docker bridge network：

```yaml
networks:
  adi-network:
    driver: bridge

services:
  azure-ai-translator:
    networks:
      - adi-network
```

請特別留意：客戶環境可能已經有既定 Docker network 或 compose network，例如 `meebot`。若 Azure AI Translator container 需要與既有服務在同一個 Docker network 溝通，請依客戶環境調整 `networks` 區塊與 service 下的 network 名稱。

例如改用既有 external network `meebot`：

```yaml
networks:
  meebot:
    external: true

services:
  azure-ai-translator:
    networks:
      - meebot
```

套用前請先在客戶環境確認 network 是否存在：

```powershell
docker network ls
```

Linux 環境同樣可使用：

```bash
docker network ls
```

若 network 不存在，需由客戶依實際架構建立，或改回 compose 自建 bridge network。

## 2.5 執行前需求

請先確認：

- Docker Desktop 已啟動。
- `docker version` 正常。
- 可連線到 `mcr.microsoft.com`。
- 已取得 Azure AI Translator container 所需的 key 與 endpoint URI。
- 目前 PowerShell 工作目錄是此 repo 根目錄。

確認 Docker：

```powershell
docker version
```

確認 Microsoft Container Registry 連線：

```powershell
Test-NetConnection mcr.microsoft.com -Port 443
```

切換到 script 所在目錄。以下路徑僅為範例，請依實際下載或 clone 的 repo 位置調整：

```powershell
cd C:\Users\fuche\OneDrive\CodexProject\build-offline-package
```

## 2.6 執行 script

若 PowerShell execution policy 阻擋本次執行，可只針對目前程序開放：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

執行：

```powershell
.\build-offline-package.ps1
```

依提示輸入：

```text
TRANSLATOR_KEY:
TRANSLATOR_ENDPOINT_URI:
```

這兩個值請從 Azure Portal 的 Azure AI Translator Resource 取得：

1. 開啟 Azure Portal。
2. 進入已建立的 Azure AI Translator resource。
3. 在左側選單選擇 `Resource Management` → `Keys and Endpoint`。
4. 複製其中一組 `KEY 1` 或 `KEY 2`，貼到 `TRANSLATOR_KEY`。
5. 複製 `Endpoint`，貼到 `TRANSLATOR_ENDPOINT_URI`。

Microsoft 官方文件說明：Azure AI Translator container 需要 API key 與 Endpoint URL，兩者可在 Translator resource 的 `Keys and Endpoint` 頁面取得。請參考 [Install and run Translator container using Docker API](https://learn.microsoft.com/en-us/azure/ai-services/translator/containers/install-run) 與 [Azure AI Translator REST API quickstart](https://learn.microsoft.com/en-us/azure/ai-services/translator/text-translation/quickstart/rest-api)。

注意事項：

- `TRANSLATOR_KEY` 以 SecureString 讀取。
- script 會產生暫時 `.env` 給 Docker Compose 使用。
- `.env` 會在流程中盡早移除，避免 key 殘留。
- 不要把 key 寫入 GitHub、README、issue 或 log。

## 2.7 預期輸出

成功時，最後會留下：

```text
archive\log-download-models_<timestamp>.log
archive\package-azure-ai-translator-container-<timestamp>.tar.gz
archive\SHA256SUMS.txt
```

package 內容包含：

```text
azure-ai-translator\models\
azure-ai-translator\license\
compose_config\dotnet_translate\TranslateFiles\
archive\oci-azure-translator-text-translation.tar
archive\run-disconnected-container-docker-compose.yaml
archive\log-download-models_<timestamp>.log
```

檢查 package：

```powershell
Get-ChildItem .\archive
```

檢查 SHA256：

```powershell
Get-Content .\archive\SHA256SUMS.txt
```

重新計算 package hash：

```powershell
$pkg = Get-ChildItem .\archive\package-azure-ai-translator-container-*.tar.gz |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

Get-FileHash $pkg.FullName -Algorithm SHA256
```

---

# 3. Windows 離線執行下載好的 Docker image

本章使用 Windows PowerShell 指令說明離線執行流程。若客戶端離線伺服器為 Linux，請參考第 5 章。

## 3.1 將 package 帶到離線機器

從有網路機器複製下列檔案到離線機器：

```text
archive\package-azure-ai-translator-container-<timestamp>.tar.gz
archive\SHA256SUMS.txt
```

建議離線機器一開始就使用 release 目錄管理部署版本。以下日期時間僅為範例，建議使用 package 產出的 timestamp 或企業內部版本號：

```text
C:\AzureAITranslatorOffline
  releases\
    20260505_150000\   # 本次部署版本
```

後續更新時請不要覆蓋此目錄，而是建立下一個 release 目錄；本次部署目錄會成為 rollback 來源。

建立本次部署的 release 目錄：

```powershell
$ReleaseDir = "C:\AzureAITranslatorOffline\releases\20260505_150000"
New-Item -ItemType Directory -Path $ReleaseDir -Force
```

將 package 放到本次部署的 release 目錄：

```text
C:\AzureAITranslatorOffline\releases\20260505_150000
```

若是從 USB 或暫存資料夾複製，可依實際路徑調整：

```powershell
Copy-Item E:\package-azure-ai-translator-container-*.tar.gz $ReleaseDir
Copy-Item E:\SHA256SUMS.txt $ReleaseDir
```

切換到本次部署的 release 目錄：

```powershell
cd $ReleaseDir
```

## 3.2 驗證 package hash

查看交付的 SHA256：

```powershell
Get-Content .\SHA256SUMS.txt
```

計算本機 package SHA256：

```powershell
$pkg = Get-ChildItem .\package-azure-ai-translator-container-*.tar.gz |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

Get-FileHash $pkg.FullName -Algorithm SHA256
```

確認 `Get-FileHash` 的 `Hash` 與 `SHA256SUMS.txt` 中的值一致。

## 3.3 解壓 package

解壓：

```powershell
tar -xzf $pkg.FullName -C .
```

確認解壓後目錄：

```powershell
Get-ChildItem
```

預期看到：

```text
azure-ai-translator
archive
package-azure-ai-translator-container-<timestamp>.tar.gz
SHA256SUMS.txt
```

確認 image tar 與離線 compose 存在：

```powershell
Test-Path .\archive\oci-azure-translator-text-translation.tar
Test-Path .\archive\run-disconnected-container-docker-compose.yaml
Test-Path .\compose_config\dotnet_translate\TranslateFiles
```

## 3.4 載入 Docker image

確認 Docker Desktop 已啟動：

```powershell
docker version
```

載入 image：

```powershell
docker load -i .\archive\oci-azure-translator-text-translation.tar
```

確認 image 已載入：

```powershell
docker images | Select-String "azure-cognitive-services/translator/text-translation"
```

## 3.5 啟動離線 container

重要：請在 package 解壓後的根目錄執行，並加上 `--project-directory .`。這可確保 compose 內的相對 volume path 指向目前根目錄的 `azure-ai-translator`，而不是 `archive` 目錄。

啟動：

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  up -d
```

確認 container：

```powershell
docker ps --filter "name=azure-ai-translator"
```

查看 log：

```powershell
docker logs azure-ai-translator
```

確認 port 5000 是否監聽：

```powershell
Get-NetTCPConnection -LocalPort 5000 -ErrorAction SilentlyContinue
```

## 3.6 測試本機 API

可用簡單 request 確認服務可連線。實際 API 路徑與參數請依 Azure AI Translator container 版本為準。

範例：

```powershell
$body = ConvertTo-Json -InputObject @(
  @{
    Text = "Hello"
  }
)

Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:5000/translate?api-version=3.0&from=en&to=zh-Hant" `
  -ContentType "application/json" `
  -Body $body
```

若 API 回應翻譯結果，代表 container 已可離線服務。

## 3.7 停止離線 container

停止：

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  down
```

確認已停止：

```powershell
docker ps --filter "name=azure-ai-translator"
```

## 3.8 離線執行常見問題

### 問題 1 docker compose 找不到 models 或 license

原因通常是從錯誤目錄執行 compose，或未加 `--project-directory .`。

請回到本次部署的 release 目錄，也就是 package 解壓根目錄：

```powershell
cd C:\AzureAITranslatorOffline\releases\20260505_150000
```

使用：

```powershell
docker compose --project-directory . -f .\archive\run-disconnected-container-docker-compose.yaml up -d
```

### 問題 2 image not found

確認 image tar 是否載入：

```powershell
docker images
```

重新載入：

```powershell
docker load -i .\archive\oci-azure-translator-text-translation.tar
```

### 問題 3 port 5000 已被占用

找出占用程序：

```powershell
Get-NetTCPConnection -LocalPort 5000 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, State, OwningProcess
```

查看程序：

```powershell
Get-Process -Id <OwningProcess>
```

若需修改 port，請編輯：

```text
archive\run-disconnected-container-docker-compose.yaml
```

將：

```yaml
ports:
  - "5000:5000"
```

改成例如：

```yaml
ports:
  - "5001:5000"
```

重新啟動：

```powershell
docker compose --project-directory . -f .\archive\run-disconnected-container-docker-compose.yaml down
docker compose --project-directory . -f .\archive\run-disconnected-container-docker-compose.yaml up -d
```

### 問題 4 container 啟動後立刻退出

查看 log：

```powershell
docker logs azure-ai-translator
```

檢查 compose：

```powershell
Get-Content .\archive\run-disconnected-container-docker-compose.yaml
```

確認以下資料夾存在：

```powershell
Test-Path .\azure-ai-translator\models
Test-Path .\azure-ai-translator\license
Test-Path .\compose_config\dotnet_translate\TranslateFiles
```

---

# 4. Windows 更新既有離線伺服器上的 image 與 models

本章使用 Windows PowerShell 指令說明既有離線伺服器的更新流程。若客戶端離線伺服器為 Linux，請參考第 6 章。

本章適用於離線伺服器已經有舊版 Azure AI Translator container、models 與 license 正在執行，並且需要使用新產出的 `package-azure-ai-translator-container-<timestamp>.tar.gz` 進行更新的情境。

更新時請不要直接將新版 package 解壓覆蓋到舊版執行目錄。建議使用「版本目錄」管理，保留舊版 package 與部署目錄，確保新版異常時可以快速 rollback。

## 4.1 建議目錄結構

建議在離線伺服器使用下列結構管理不同版本：

```text
C:\AzureAITranslatorOffline
  releases\
    20260501_120000\   # 舊版
    20260505_150000\   # 新版
```

建立新版 release 目錄：

```powershell
New-Item -ItemType Directory -Path C:\AzureAITranslatorOffline\releases\20260505_150000 -Force
```

切換到新版 release 目錄：

```powershell
cd C:\AzureAITranslatorOffline\releases\20260505_150000
```

將新版 package 與 `SHA256SUMS.txt` 複製到此目錄：

```text
package-azure-ai-translator-container-<timestamp>.tar.gz
SHA256SUMS.txt
```

## 4.2 驗證新版 package

查看交付的 SHA256：

```powershell
Get-Content .\SHA256SUMS.txt
```

計算新版 package 的 SHA256：

```powershell
$pkg = Get-ChildItem .\package-azure-ai-translator-container-*.tar.gz |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

Get-FileHash $pkg.FullName -Algorithm SHA256
```

確認 `Get-FileHash` 的 `Hash` 與 `SHA256SUMS.txt` 中的值一致。

## 4.3 解壓新版 package

在新版 release 目錄中解壓：

```powershell
tar -xzf $pkg.FullName -C .
```

確認新版 package 已解壓：

```powershell
Test-Path .\archive\oci-azure-translator-text-translation.tar
Test-Path .\archive\run-disconnected-container-docker-compose.yaml
Test-Path .\azure-ai-translator\models
Test-Path .\azure-ai-translator\license
Test-Path .\compose_config\dotnet_translate\TranslateFiles
```

## 4.4 停止舊版 container

請切換到舊版 release 目錄，使用舊版的 compose 檔停止目前正在執行的 container。

範例：

```powershell
cd C:\AzureAITranslatorOffline\releases\20260501_120000
```

停止舊版 container：

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  down
```

確認已停止：

```powershell
docker ps --filter "name=azure-ai-translator"
```

## 4.5 載入新版 image

切換到新版 release 目錄：

```powershell
cd C:\AzureAITranslatorOffline\releases\20260505_150000
```

載入新版 image：

```powershell
docker load -i .\archive\oci-azure-translator-text-translation.tar
```

確認 image：

```powershell
docker images | Select-String "azure-cognitive-services/translator/text-translation"
```

注意：本工具目前使用的 image tag 是：

```text
mcr.microsoft.com/azure-cognitive-services/translator/text-translation:latest
```

因此新版 `docker load` 完成後，`latest` 會指向新版 image。

## 4.6 啟動新版 container

請在新版 release 目錄執行，並保留 `--project-directory .`：

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  up -d
```

確認 container 狀態：

```powershell
docker ps --filter "name=azure-ai-translator"
```

查看 log：

```powershell
docker logs azure-ai-translator
```

確認 port 5000：

```powershell
Get-NetTCPConnection -LocalPort 5000 -ErrorAction SilentlyContinue
```

## 4.7 更新後驗證

使用第 3.6 節的本機 API 測試方式，確認新版 container 可正常回應。

也可以確認目前 compose 使用的 models 與 config 值：

```powershell
Get-Content .\archive\run-disconnected-container-docker-compose.yaml |
  Select-String "MODELS|TRANSLATORSYSTEMCONFIG"
```

## 4.8 Rollback 回舊版

若新版啟動失敗或 API 驗證不通過，請停止新版 container。

在新版 release 目錄執行：

```powershell
cd C:\AzureAITranslatorOffline\releases\20260505_150000
```

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  down
```

切回舊版 release 目錄：

```powershell
cd C:\AzureAITranslatorOffline\releases\20260501_120000
```

重新載入舊版 image：

```powershell
docker load -i .\archive\oci-azure-translator-text-translation.tar
```

啟動舊版 container：

```powershell
docker compose `
  --project-directory . `
  -f .\archive\run-disconnected-container-docker-compose.yaml `
  up -d
```

確認舊版已恢復：

```powershell
docker ps --filter "name=azure-ai-translator"
docker logs azure-ai-translator
```

## 4.9 更新注意事項

- 不要將新版 package 直接解壓覆蓋到舊版 release 目錄。
- 不要刪除舊版 release 目錄，直到新版已通過驗證並完成觀察期。
- 新舊版本不能同時使用預設 compose 啟動，因為 container name 與 host port 固定為：

```yaml
container_name: azure-ai-translator
ports:
  - "5000:5000"
```

- 若需要新舊版本並行測試，必須另外調整新版 compose 的 `container_name` 與 host port，例如改成 `5001:5000`。
- 更新前建議記錄舊版 package 目錄、SHA256、啟動時間與測試結果。
- 更新後若確認新版穩定，再依企業保留政策清理舊版 release。

---

# 5. Linux 離線執行下載好的 Docker image

本章適用於客戶端離線伺服器為 Linux 的情境。線上打包仍由 Windows 端執行 `build-offline-package.ps1`，離線 Linux 伺服器只負責接收 package、載入 image、掛載 models/license，並啟動 Azure AI Translator container。

## 5.1 Linux 伺服器前置需求

請先確認 Linux 離線伺服器已具備：

- Docker Engine。
- Docker Compose plugin，也就是可使用 `docker compose` 指令。
- 可使用 `tar` 解壓 `.tar.gz`。
- 具備啟動 container 與綁定 port `5000` 的權限。

確認 Docker Engine：

```bash
docker version
```

確認 Docker Compose plugin：

```bash
docker compose version
```

確認 Docker daemon 狀態：

```bash
sudo systemctl status docker
```

若目前使用者沒有 docker 權限，可以先用 `sudo docker` 執行本章指令，或由系統管理員將使用者加入 `docker` 群組：

```bash
sudo usermod -aG docker "$USER"
```

加入群組後需重新登入 shell session：

```bash
exit
```

重新登入後確認：

```bash
docker ps
```

## 5.2 將 package 放到 Linux 離線伺服器

建議使用 `/opt/azure-ai-translator-offline` 作為離線部署根目錄，並一開始就使用 release 目錄管理部署版本。以下路徑與日期時間僅為範例，請依客戶環境調整。

建議目錄結構：

```text
/opt/azure-ai-translator-offline
  releases/
    20260505_150000/   # 本次部署版本
```

後續更新時請不要覆蓋此目錄，而是建立下一個 release 目錄；本次部署目錄會成為 rollback 來源。

建立本次部署的 release 目錄：

```bash
sudo mkdir -p /opt/azure-ai-translator-offline/releases/20260505_150000
sudo chown -R "$USER":"$USER" /opt/azure-ai-translator-offline
```

切換到本次部署的 release 目錄：

```bash
cd /opt/azure-ai-translator-offline/releases/20260505_150000
```

將下列檔案複製到此目錄：

```text
package-azure-ai-translator-container-<timestamp>.tar.gz
SHA256SUMS.txt
```

若是從 USB 或掛載磁碟複製，可依實際掛載點調整：

```bash
cp /mnt/usb/package-azure-ai-translator-container-*.tar.gz .
cp /mnt/usb/SHA256SUMS.txt .
```

## 5.3 驗證 package hash

確認檔案：

```bash
ls -lh
```

查看 SHA256SUMS：

```bash
cat SHA256SUMS.txt
```

使用 `sha256sum -c` 驗證：

```bash
sha256sum -c SHA256SUMS.txt
```

預期結果：

```text
package-azure-ai-translator-container-<timestamp>.tar.gz: OK
```

若檔名不一致或 package 被重新命名，請手動計算：

```bash
sha256sum package-azure-ai-translator-container-*.tar.gz
```

確認輸出的 hash 與 `SHA256SUMS.txt` 中的值一致。

## 5.4 解壓 package

設定 package 變數：

```bash
PKG="$(ls -t package-azure-ai-translator-container-*.tar.gz | head -n 1)"
```

解壓：

```bash
tar -xzf "$PKG" -C .
```

確認解壓後目錄：

```bash
find . -maxdepth 3 -type d | sort
```

確認必要檔案存在：

```bash
test -f ./archive/oci-azure-translator-text-translation.tar
test -f ./archive/run-disconnected-container-docker-compose.yaml
test -d ./azure-ai-translator/models
test -d ./azure-ai-translator/license
test -d ./compose_config/dotnet_translate/TranslateFiles
```

## 5.5 載入 Docker image

載入 image：

```bash
docker load -i ./archive/oci-azure-translator-text-translation.tar
```

若需要 sudo：

```bash
sudo docker load -i ./archive/oci-azure-translator-text-translation.tar
```

確認 image：

```bash
docker images | grep 'azure-cognitive-services/translator/text-translation'
```

## 5.6 啟動離線 container

重要：請在 package 解壓後的根目錄執行，並加上 `--project-directory .`。這可確保 compose 內的相對 volume path 指向目前根目錄的 `azure-ai-translator`，而不是 `archive` 目錄。

啟動：

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  up -d
```

若需要 sudo：

```bash
sudo docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  up -d
```

確認 container：

```bash
docker ps --filter "name=azure-ai-translator"
```

查看 log：

```bash
docker logs azure-ai-translator
```

確認 port 5000 是否監聽：

```bash
ss -ltnp | grep ':5000'
```

## 5.7 測試本機 API

使用 `curl` 測試服務是否可連線：

```bash
curl -sS \
  -X POST \
  'http://localhost:5000/translate?api-version=3.0&from=en&to=zh-Hant' \
  -H 'Content-Type: application/json' \
  --data '[{"Text":"Hello"}]'
```

若系統有安裝 `jq`，可格式化輸出：

```bash
curl -sS \
  -X POST \
  'http://localhost:5000/translate?api-version=3.0&from=en&to=zh-Hant' \
  -H 'Content-Type: application/json' \
  --data '[{"Text":"Hello"}]' | jq .
```

若 API 回應翻譯結果，代表 container 已可離線服務。

## 5.8 停止離線 container

停止：

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  down
```

若需要 sudo：

```bash
sudo docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  down
```

確認已停止：

```bash
docker ps --filter "name=azure-ai-translator"
```

## 5.9 Linux 離線執行常見問題

### 問題 1 Permission denied while trying to connect to Docker daemon

原因：

- 目前使用者不在 `docker` 群組。
- Docker daemon socket 需要 root 權限。

解法一：使用 sudo：

```bash
sudo docker ps
```

解法二：由系統管理員加入 docker 群組：

```bash
sudo usermod -aG docker "$USER"
```

重新登入後確認：

```bash
docker ps
```

### 問題 2 docker compose 指令不存在

確認：

```bash
docker compose version
```

若出現 `docker: 'compose' is not a docker command`，表示 Docker Compose plugin 尚未安裝。請依客戶 Linux 發行版與企業套件來源安裝 Docker Compose plugin。

### 問題 3 models 或 license 找不到

通常是從錯誤目錄執行 compose，或未加 `--project-directory .`。

請回到本次部署的 release 目錄，也就是 package 解壓根目錄：

```bash
cd /opt/azure-ai-translator-offline/releases/20260505_150000
```

使用：

```bash
docker compose --project-directory . -f ./archive/run-disconnected-container-docker-compose.yaml up -d
```

### 問題 4 port 5000 已被占用

確認占用：

```bash
sudo ss -ltnp | grep ':5000'
```

若需修改 port，請編輯：

```bash
vi ./archive/run-disconnected-container-docker-compose.yaml
```

將：

```yaml
ports:
  - "5000:5000"
```

改成例如：

```yaml
ports:
  - "5001:5000"
```

重新啟動：

```bash
docker compose --project-directory . -f ./archive/run-disconnected-container-docker-compose.yaml down
docker compose --project-directory . -f ./archive/run-disconnected-container-docker-compose.yaml up -d
```

### 問題 5 container 啟動後立刻退出

查看 log：

```bash
docker logs azure-ai-translator
```

確認 compose 與掛載目錄：

```bash
cat ./archive/run-disconnected-container-docker-compose.yaml
ls -la ./azure-ai-translator/models
ls -la ./azure-ai-translator/license
```

---

# 6. Linux 更新既有離線伺服器上的 image 與 models

本章適用於 Linux 離線伺服器已經有舊版 Azure AI Translator container、models 與 license 正在執行，並且需要使用新產出的 package 進行更新的情境。

更新原則與 Windows 相同：不要直接覆蓋舊版目錄，請使用版本目錄保留 rollback 能力。

## 6.1 建議目錄結構

建議在 Linux 離線伺服器使用下列結構：

```text
/opt/azure-ai-translator-offline
  releases/
    20260501_120000/   # 舊版
    20260505_150000/   # 新版
```

建立新版 release 目錄：

```bash
sudo mkdir -p /opt/azure-ai-translator-offline/releases/20260505_150000
sudo chown -R "$USER":"$USER" /opt/azure-ai-translator-offline
```

切換到新版 release 目錄：

```bash
cd /opt/azure-ai-translator-offline/releases/20260505_150000
```

將新版 package 與 `SHA256SUMS.txt` 放入此目錄。

## 6.2 驗證新版 package

確認檔案：

```bash
ls -lh
```

驗證 SHA256：

```bash
sha256sum -c SHA256SUMS.txt
```

若 package 檔名與 `SHA256SUMS.txt` 不一致，請手動計算：

```bash
sha256sum package-azure-ai-translator-container-*.tar.gz
```

## 6.3 解壓新版 package

設定 package 變數：

```bash
PKG="$(ls -t package-azure-ai-translator-container-*.tar.gz | head -n 1)"
```

解壓：

```bash
tar -xzf "$PKG" -C .
```

確認新版內容：

```bash
test -f ./archive/oci-azure-translator-text-translation.tar
test -f ./archive/run-disconnected-container-docker-compose.yaml
test -d ./azure-ai-translator/models
test -d ./azure-ai-translator/license
test -d ./compose_config/dotnet_translate/TranslateFiles
```

## 6.4 停止舊版 container

切換到舊版 release 目錄：

```bash
cd /opt/azure-ai-translator-offline/releases/20260501_120000
```

停止舊版 container：

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  down
```

若需要 sudo：

```bash
sudo docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  down
```

確認已停止：

```bash
docker ps --filter "name=azure-ai-translator"
```

## 6.5 載入新版 image

切換到新版 release 目錄：

```bash
cd /opt/azure-ai-translator-offline/releases/20260505_150000
```

載入新版 image：

```bash
docker load -i ./archive/oci-azure-translator-text-translation.tar
```

確認 image：

```bash
docker images | grep 'azure-cognitive-services/translator/text-translation'
```

注意：本工具目前使用的 image tag 是：

```text
mcr.microsoft.com/azure-cognitive-services/translator/text-translation:latest
```

因此新版 `docker load` 完成後，`latest` 會指向新版 image。

## 6.6 啟動新版 container

在新版 release 目錄啟動：

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  up -d
```

確認狀態：

```bash
docker ps --filter "name=azure-ai-translator"
docker logs azure-ai-translator
```

確認 port：

```bash
ss -ltnp | grep ':5000'
```

## 6.7 更新後驗證

使用本機 API 測試：

```bash
curl -sS \
  -X POST \
  'http://localhost:5000/translate?api-version=3.0&from=en&to=zh-Hant' \
  -H 'Content-Type: application/json' \
  --data '[{"Text":"Hello"}]'
```

確認目前 compose 使用的 models 與 config：

```bash
grep -E 'MODELS|TRANSLATORSYSTEMCONFIG' ./archive/run-disconnected-container-docker-compose.yaml
```

## 6.8 Rollback 回舊版

若新版啟動失敗或 API 驗證不通過，請先停止新版。

切換到新版 release 目錄：

```bash
cd /opt/azure-ai-translator-offline/releases/20260505_150000
```

停止新版 container：

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  down
```

切換回舊版 release 目錄：

```bash
cd /opt/azure-ai-translator-offline/releases/20260501_120000
```

重新載入舊版 image：

```bash
docker load -i ./archive/oci-azure-translator-text-translation.tar
```

啟動舊版 container：

```bash
docker compose \
  --project-directory . \
  -f ./archive/run-disconnected-container-docker-compose.yaml \
  up -d
```

確認舊版已恢復：

```bash
docker ps --filter "name=azure-ai-translator"
docker logs azure-ai-translator
```

## 6.9 Linux 更新注意事項

- 不要將新版 package 直接解壓覆蓋到舊版 release 目錄。
- 不要刪除舊版 release 目錄，直到新版已通過驗證並完成觀察期。
- 新舊版本不能同時使用預設 compose 啟動，因為 container name 與 host port 固定為：

```yaml
container_name: azure-ai-translator
ports:
  - "5000:5000"
```

- 若需要新舊版本並行測試，必須另外調整新版 compose 的 `container_name` 與 host port，例如改成 `5001:5000`。
- 若 Linux 主機啟用 SELinux，volume mount 可能受到額外限制，需依企業安全政策調整 label 或掛載策略。
- 更新前建議記錄舊版 release 目錄、SHA256、image ID、啟動時間與測試結果。
- 更新後若確認新版穩定，再依企業保留政策清理舊版 release。

---

# 7. 參考文件

- [Docker Desktop for Windows 官方安裝文件](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Docker Desktop WSL 2 backend 官方文件](https://docs.docker.com/desktop/features/wsl/)
- [Microsoft WSL 安裝文件](https://learn.microsoft.com/windows/wsl/install)
- [Microsoft Azure AI Translator container 安裝與執行文件](https://learn.microsoft.com/en-us/azure/ai-services/translator/containers/install-run)
- [Microsoft Azure AI Translator REST API quickstart](https://learn.microsoft.com/en-us/azure/ai-services/translator/text-translation/quickstart/rest-api)
- [pichuang/azure-ai-playground - Azure AI Translator Container](https://github.com/pichuang/azure-ai-playground/tree/main/azure-ai-translator-container)
