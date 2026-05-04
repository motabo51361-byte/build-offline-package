# Azure AI Translator Offline Package Builder

本 repo 提供 `build-offline-package.ps1`，用於在有網路的 Windows 11 + Docker Desktop 環境中下載 Azure AI Translator container image、models、license，並打包成可帶到離線環境執行的交付檔。

## 目錄

1. [Docker Desktop 安裝指南 Windows 11 + WSL2](#1-docker-desktop-安裝指南-windows-11--wsl2)
2. [執行 build-offline-package.ps1](#2-執行-build-offline-packageps1)
3. [離線執行下載好的 Docker image](#3-離線執行下載好的-docker-image)
4. [參考文件](#4-參考文件)

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

## 2.2 執行前需求

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

切換到 script 所在目錄：

```powershell
cd C:\Users\fuche\OneDrive\CodexProject\build-offline-package
```

## 2.3 執行 script

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

注意事項：

- `TRANSLATOR_KEY` 以 SecureString 讀取。
- script 會產生暫時 `.env` 給 Docker Compose 使用。
- `.env` 會在流程中盡早移除，避免 key 殘留。
- 不要把 key 寫入 GitHub、README、issue 或 log。

## 2.4 預期輸出

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

# 3. 離線執行下載好的 Docker image

## 3.1 將 package 帶到離線機器

從有網路機器複製下列檔案到離線機器：

```text
archive\package-azure-ai-translator-container-<timestamp>.tar.gz
archive\SHA256SUMS.txt
```

在離線機器建立工作目錄：

```powershell
New-Item -ItemType Directory -Path C:\AzureAITranslatorOffline -Force
```

將 package 放到：

```text
C:\AzureAITranslatorOffline
```

切換工作目錄：

```powershell
cd C:\AzureAITranslatorOffline
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
$body = @(
  @{
    Text = "Hello"
  }
) | ConvertTo-Json

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

請回到 package 解壓根目錄：

```powershell
cd C:\AzureAITranslatorOffline
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
```

---

# 4. 參考文件

- [Docker Desktop for Windows 官方安裝文件](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Docker Desktop WSL 2 backend 官方文件](https://docs.docker.com/desktop/features/wsl/)
- [Microsoft WSL 安裝文件](https://learn.microsoft.com/windows/wsl/install)
