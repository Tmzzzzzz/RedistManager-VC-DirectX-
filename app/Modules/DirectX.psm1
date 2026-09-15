# ============================================================
#  Modules/DirectX.psm1 —— DirectX 运行库模块
#
#  模块契约（详见 README「如何添加新模块」）：
#    · 文件名基名 = 模块 Id（PascalCase）：DirectX → Id = "directx"
#    · 导出 4 个函数：Get-DirectXManifest / Get-DirectXDetection /
#      Invoke-DirectXAction / Get-DirectXReport
#    · Kind = "List"（只读列表 + 「检测 / 修复」按钮）
#    · 依赖 Core 导出的共享函数（Get-ModuleConfig / Start-VCRedistDownload /
#      Test-VCRedistPackage / Invoke-ElevatedProcess 等）
#  本文件必须保存为 UTF-8 with BOM。
# ============================================================

# ---------- 清单 ----------

function Get-DirectXManifest {
    return [PSCustomObject]@{
        Title = 'DirectX 运行库'
        Kind  = 'List'
        Order = 2
    }
}

# ---------- 检测（只读列表） ----------

function Get-DirectXDetection {
    $cfg = Get-ModuleConfig -Id 'directx'
    if (-not $cfg) { throw '缺少 DirectX 模块配置（modules.directx）' }

    $groupMap = @{
        'd3dx9_43.dll'       = 'DirectX 9'
        'd3dx10_43.dll'      = 'DirectX 10'
        'd3dx11_43.dll'      = 'DirectX 11'
        'd3dcompiler_43.dll' = 'D3D Compiler'
        'xinput1_3.dll'      = 'XInput'
        'XAudio2_7.dll'      = 'XAudio2'
    }

    $sys32 = Join-Path $env:WINDIR 'System32'
    $rows = @()
    foreach ($dll in $cfg.dlls) {
        $path = Join-Path $sys32 $dll
        if (Test-Path -LiteralPath $path) {
            $v = $null
            try { $v = (Get-Item -LiteralPath $path -ErrorAction SilentlyContinue).VersionInfo.FileVersion } catch { }
            $rows += [PSCustomObject]@{
                Name      = $dll
                Category  = $groupMap[$dll]
                StateKey  = 'installed'
                StateText = '已就绪'
                Detail    = $v
            }
        } else {
            $rows += [PSCustomObject]@{
                Name      = $dll
                Category  = $groupMap[$dll]
                StateKey  = 'missing'
                StateText = '缺失'
                Detail    = '未找到该文件'
            }
        }
    }

    $missing = @($rows | Where-Object { $_.StateKey -eq 'missing' })
    $total   = $rows.Count
    $present = $total - $missing.Count

    if ($missing.Count -eq 0) {
        $summary = [PSCustomObject]@{ StateKey = 'ok'; StateText = '已就绪，无需修复'; StateDetail = ('{0}/{1} 组件就绪' -f $present, $total) }
    } elseif ($present -eq 0) {
        $summary = [PSCustomObject]@{ StateKey = 'missing'; StateText = '全部缺失'; StateDetail = ('缺失：{0}' -f ($missing.Name -join ', ')) }
    } else {
        $summary = [PSCustomObject]@{ StateKey = 'partial'; StateText = '部分缺失'; StateDetail = ('缺失：{0}' -f ($missing.Name -join ', ')) }
    }

    return [PSCustomObject]@{
        Rows    = $rows
        Summary = $summary
        Extra   = @{}
    }
}

# ---------- 修复（下载 → 解压 → DXSETUP /silent） ----------

function Invoke-DirectXAction {
    param(
        [string]$Operation,
        $Rows,
        [hashtable]$Sync
    )
    $results = @()

    if ($Operation -ne 'repair') { return $results }

    try {
        $cfg  = Get-ModuleConfig -Id 'directx'
        $inst = $cfg.installer
        $dest = Join-Path (Get-DownloadDirectory) $inst.fileName

        $Sync.StatusText = '正在下载 DirectX 运行库 ...'
        Start-VCRedistDownload -Url $inst.url -DestPath $dest -Sync $Sync | Out-Null
        $Sync.StatusText = '正在校验 DirectX 运行库（数字签名 / SHA256）...'
        $chk = Test-VCRedistPackage -Path $dest -ExpectedSha256 ([string]$inst.sha256)
        if (-not $chk.Passed) { throw ('校验失败：签名={0} 哈希={1}' -f $chk.SignatureOk, $chk.HashOk) }
        $Sync.LogLines += ('  下载完成：{0}（签名：{1}）' -f (Format-Bytes (Get-Item $dest).Length), $chk.SignatureOk) + "`r`n"

        $extractDir = Join-Path (Get-DownloadDirectory) 'directx_extract'
        if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        $Sync.StatusText = '正在解压 DirectX 安装包 ...'
        $code = Invoke-ElevatedProcess -FilePath $dest -ArgumentList @('/Q', ('/T:{0}' -f $extractDir))
        if (-not (Test-ExitSuccess $code)) { throw ('解压失败（退出码 {0}）' -f $code) }

        $dxsetup = Join-Path $extractDir 'DXSETUP.exe'
        if (-not (Test-Path -LiteralPath $dxsetup)) { throw '解压后未找到 DXSETUP.exe' }

        $Sync.StatusText = '正在静默安装 DirectX 组件（将弹出 UAC 提权）...'
        $code2 = Invoke-ElevatedProcess -FilePath $dxsetup -ArgumentList @('/silent')
        if (Test-ExitSuccess $code2) {
            $results += '✓ DirectX 运行库安装成功'
            $Sync.LogLines += '  DirectX 修复完成' + "`r`n"
            Write-VCRedistLog -Message ('DirectX 修复成功（退出码 {0}）' -f $code2) -Level INFO
        } else {
            $results += ('✗ DirectX 运行库（退出码 {0}）' -f $code2)
            Write-VCRedistLog -Message ('DirectX 修复未成功（退出码 {0}）' -f $code2) -Level WARN
        }
    } catch {
        $Sync.LogLines += ('  失败：{0}' -f $_.Exception.Message) + "`r`n"
        $results += ('✗ DirectX：{0}' -f $_.Exception.Message)
        Write-VCRedistLog -Message ('DirectX 修复失败：{0}' -f $_.Exception.Message) -Level ERROR
    }

    $Sync.ProgressPercent = 0
    return $results
}

# ---------- 诊断报告片段 ----------

function Get-DirectXReport {
    param($Detection)
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine(('{0}：{1}' -f $Detection.Summary.StateText, $Detection.Summary.StateDetail))
    $null = $sb.AppendLine('组件明细：')
    foreach ($r in $Detection.Rows) {
        $line = '  [{0}] {1}（{2}）' -f $r.StateText, $r.Name, $r.Category
        if ($r.StateKey -eq 'installed' -and $r.Detail) { $line += ' —— ' + $r.Detail }
        $null = $sb.AppendLine($line)
    }
    return $sb.ToString()
}

Export-ModuleMember -Function Get-DirectXManifest, Get-DirectXDetection, Invoke-DirectXAction, Get-DirectXReport
