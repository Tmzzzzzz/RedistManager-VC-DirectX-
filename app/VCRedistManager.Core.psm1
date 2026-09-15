# ============================================================
#  VCRedistManager.Core.psm1
#  运行库管理工具 —— 核心基础设施
#    · 配置加载 / 迁移、日志、下载、签名+SHA256 校验、UAC 提权
#    · 模块注册表（自动发现 Modules\*.psm1）与分发
#    · 通用检测原语（注册表 / DLL / WinSxS）
#
#  说明：本文件不包含任何具体运行库（VC / DirectX）业务逻辑，
#        具体模块放在 Modules\*.psm1，按「模块契约」实现。
#  本文件必须保存为 UTF-8 with BOM（见 README）。
# ============================================================

$script:Config  = $null
$script:Modules = @()

# ---------- 基础工具 ----------

function Test-Is64BitOS {
    return [System.Environment]::Is64BitOperatingSystem
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Set-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch { }
}

function Get-DownloadDirectory {
    $dir = $script:Config.downloadDir
    $dir = $dir.Replace('%TEMP%', $env:TEMP)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# ---------- 日志 ----------

function Write-VCRedistLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'VCRedistManager\logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        [System.IO.File]::AppendAllText((Join-Path $logDir 'VCRedistManager.log'), $line + "`r`n", [System.Text.Encoding]::UTF8)
    } catch { }
}

function Get-VCRedistLogPath {
    $logDir = Join-Path $env:LOCALAPPDATA 'VCRedistManager\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    return (Join-Path $logDir 'VCRedistManager.log')
}

# ---------- 配置 ----------

function Initialize-VCRedistConfig {
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) { throw "找不到配置文件：$ConfigPath" }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $script:Config = $raw | ConvertFrom-Json

    # 迁移旧结构（v1.1 及更早）：顶层 versions / necessityRules / directx → modules.{id}
    if (-not $script:Config.modules) {
        $m = [PSCustomObject]@{}
        if ($script:Config.versions) {
            $vc = [PSCustomObject]@{
                versions       = $script:Config.versions
                necessityRules = $script:Config.necessityRules
            }
            $m | Add-Member -MemberType NoteProperty -Name 'vc' -Value $vc
        }
        if ($script:Config.directx) {
            $m | Add-Member -MemberType NoteProperty -Name 'directx' -Value $script:Config.directx
        }
        $script:Config | Add-Member -MemberType NoteProperty -Name 'modules' -Value $m
    }

    Set-Tls12
    return $script:Config
}

function Get-VCRedistConfig {
    return $script:Config
}

function Get-ModuleConfig {
    param([string]$Id)
    if (-not $script:Config -or -not $script:Config.modules) { return $null }
    return $script:Config.modules.$Id
}

# ---------- 模块注册表 ----------

function Initialize-VCRedistModules {
    param([string]$ModulesDir)
    $script:Modules = @()
    if (-not (Test-Path -LiteralPath $ModulesDir)) { return $script:Modules }

    $files = Get-ChildItem -LiteralPath $ModulesDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $idCased    = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $manifestFn = "Get-${idCased}Manifest"
        try {
            # -Global 必须：本函数在 Core 的模块作用域内运行，若不指定 -Global，
            # 模块会被导入到 Core 的会话状态，主脚本 / 各模块函数将无法按命名约定调用。
            Import-Module $f.FullName -Force -Global -ErrorAction Stop
            if (-not (Get-Command $manifestFn -ErrorAction SilentlyContinue)) {
                Write-VCRedistLog -Message ('模块 {0} 缺少清单函数 {1}，已跳过' -f $f.Name, $manifestFn) -Level WARN
                continue
            }
            $manifest = & $manifestFn
            $script:Modules += [PSCustomObject]@{
                Id       = $idCased.ToLowerInvariant()
                Title    = [string]$manifest.Title
                Kind     = [string]$manifest.Kind
                Order    = [int]$manifest.Order
                FileName = $f.Name
                DetectFn = "Get-${idCased}Detection"
                ActionFn = "Invoke-${idCased}Action"
                ReportFn = "Get-${idCased}Report"
            }
        } catch {
            Write-VCRedistLog -Message ('模块 {0} 加载失败：{1}' -f $f.Name, $_.Exception.Message) -Level ERROR
        }
    }
    $script:Modules = @($script:Modules | Sort-Object Order, Id)
    return $script:Modules
}

function Get-VCRedistModules {
    return $script:Modules
}

function Get-VCRedistModule {
    param([string]$Id)
    return @($script:Modules | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
}

# ---------- 模块分发 ----------

function Get-AllModuleDetection {
    $results = @()
    foreach ($m in $script:Modules) {
        $det = & $m.DetectFn
        # 给行对象打上模块标记，便于 UI 按模块分发
        foreach ($r in @($det.Rows)) {
            Add-Member -InputObject $r -MemberType NoteProperty -Name 'ModuleId' -Value $m.Id -Force
        }
        $results += [PSCustomObject]@{
            Id     = $m.Id
            Title  = $m.Title
            Kind   = $m.Kind
            Result = $det
        }
    }
    return $results
}

function Invoke-ModuleOperation {
    param([string]$ModuleId, [string]$Operation, $Rows, [hashtable]$Sync)
    $m = Get-VCRedistModule -Id $ModuleId
    if (-not $m) { throw "未找到模块：$ModuleId" }
    return (& $m.ActionFn -Operation $Operation -Rows $Rows -Sync $Sync)
}

function Invoke-AllModuleActions {
    param([string]$Operation, $Rows, [hashtable]$Sync)
    $all = @()
    foreach ($g in @($Rows | Group-Object ModuleId)) {
        $all += @(Invoke-ModuleOperation -ModuleId $g.Name -Operation $Operation -Rows @($g.Group) -Sync $Sync)
    }
    return $all
}

# ---------- 检测原语（通用，供各模块复用） ----------

function Get-DllCheckResult {
    param(
        [string]$Arch,
        [string[]]$Dlls,
        [string]$Mode,
        [string]$WinsxsPattern
    )
    $dir = if ($Arch -eq 'x64') { Join-Path $env:WINDIR 'System32' } else { Join-Path $env:WINDIR 'SysWOW64' }

    $present = @()
    $missing = @()
    foreach ($dll in $Dlls) {
        $f = Join-Path $dir $dll
        if (Test-Path -LiteralPath $f) {
            $v = $null
            try { $v = (Get-Item -LiteralPath $f -ErrorAction SilentlyContinue).VersionInfo.FileVersion } catch { }
            $present += [PSCustomObject]@{ Dll = $dll; Version = $v }
        } else {
            $missing += $dll
        }
    }

    $winsxsFound = $false
    if ($Mode -eq 'winsxs' -and $WinsxsPattern) {
        $archPrefix = if ($Arch -eq 'x64') { 'amd64_' } else { 'x86_' }
        $filter = "$archPrefix$WinsxsPattern*"
        $winsxsFound = @(Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'WinSxS') -Directory -Filter $filter -ErrorAction SilentlyContinue).Count -gt 0
    }

    return [PSCustomObject]@{
        Present     = $present
        Missing     = $missing
        AllPresent  = ($missing.Count -eq 0 -and $Dlls.Count -gt 0)
        AnyPresent  = ($present.Count -gt 0)
        WinsxsFound = $winsxsFound
    }
}

# ---------- 下载 ----------

function Start-VCRedistDownload {
    param(
        [string]$Url,
        [string]$DestPath,
        [hashtable]$Sync
    )
    Set-Tls12
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000

    $response = $request.GetResponse()
    $total = $response.ContentLength
    $stream = $response.GetResponseStream()
    $fs = [System.IO.File]::Create($DestPath)
    $buf = New-Object byte[] 65536
    $downloaded = 0L
    $Sync.ProgressPercent = 0
    $Sync.BytesDownloaded = 0
    $Sync.BytesTotal = $total

    try {
        while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $read)
            $downloaded += $read
            $Sync.BytesDownloaded = $downloaded
            $Sync.BytesTotal = $total
            if ($total -gt 0) { $Sync.ProgressPercent = [int](($downloaded / $total) * 100) }
            $Sync.StatusText = ('正在下载 {0} / {1}' -f (Format-Bytes $downloaded), (Format-Bytes $total))
            if ($Sync.CancelRequested) { break }
        }
    } finally {
        $fs.Close()
        $stream.Close()
        $response.Close()
    }

    if ($Sync.CancelRequested -or $downloaded -eq 0) {
        try { Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue } catch { }
        if ($Sync.CancelRequested) { throw '已取消下载' }
        throw '下载失败：未获取到任何数据（可能网络受限或链接失效）'
    }
    return $downloaded
}

function Clear-VCRedistCache {
    if (-not $script:Config) { throw '请先调用 Initialize-VCRedistConfig' }
    $dir = Get-DownloadDirectory
    $removed = 0
    $freed = 0L
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
            $freed += $_.Length
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    return [PSCustomObject]@{ RemovedCount = $removed; FreedBytes = $freed }
}

# ---------- 校验：签名 + SHA256 ----------

function Test-VCRedistPackage {
    param(
        [string]$Path,
        [string]$ExpectedSha256 = ''
    )
    $result = [PSCustomObject]@{
        SignatureOk     = $false
        SignatureDetail  = ''
        HashOk           = $null
        HashActual       = ''
        Passed           = $false
    }

    # 1) Authenticode 数字签名
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -match [regex]::Escape($script:Config.signatureSubject))) {
            $result.SignatureOk = $true
            $result.SignatureDetail = $sig.SignerCertificate.Subject
        } else {
            $result.SignatureOk = $false
            $result.SignatureDetail = ('状态={0}' -f $sig.Status)
        }
    } catch {
        $result.SignatureOk = $false
        $result.SignatureDetail = ('签名读取异常：{0}' -f $_.Exception.Message)
    }

    # 2) SHA256（仅当配置了期望哈希时强制校验）
    try {
        $result.HashActual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    } catch { $result.HashActual = '' }

    if ($ExpectedSha256) {
        $result.HashOk = ($result.HashActual -eq $ExpectedSha256.ToUpperInvariant())
    } else {
        $result.HashOk = $null
    }

    $result.Passed = ($result.SignatureOk -and ($null -eq $result.HashOk -or $result.HashOk -eq $true))
    return $result
}

# ---------- 安装 / 卸载（通用提权） ----------

function Invoke-ElevatedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Verb RunAs -Wait -PassThru
    return $p.ExitCode
}

function Test-ExitSuccess {
    param([int]$ExitCode)
    return $ExitCode -in @(0, 3010, 1641)
}
