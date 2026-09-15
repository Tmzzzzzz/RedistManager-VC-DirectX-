# ============================================================
#  Modules/Vc.psm1 —— VC 运行库模块
#
#  模块契约（详见 README「如何添加新模块」）：
#    · 文件名基名 = 模块 Id（PascalCase）：Vc → Id = "vc"
#    · 导出 4 个函数：Get-VcManifest / Get-VcDetection / Invoke-VcAction / Get-VcReport
#    · Kind = "Table"（逐行可操作：勾选 + 安装/卸载/检查）
#    · 依赖 Core 导出的共享函数（Get-ModuleConfig / Get-DllCheckResult /
#      Start-RedistDownload / Test-RedistPackage / Invoke-ElevatedProcess 等）
#  本文件必须保存为 UTF-8 with BOM。
# ============================================================

# ---------- 清单 ----------

function Get-VcManifest {
    return [PSCustomObject]@{
        Title = 'VC 运行库'
        Kind  = 'Table'
        Order = 1
    }
}

# ---------- 版本 / 架构识别（内部） ----------

function Resolve-VCVersionId {
    param([string]$DisplayName)
    if ($DisplayName -match '2015-2022|\bv14\b|2015|2017|2019|2022') { return 'vc2015-2022' }
    if ($DisplayName -match '2013') { return 'vc2013' }
    if ($DisplayName -match '2012') { return 'vc2012' }
    if ($DisplayName -match '2010') { return 'vc2010' }
    if ($DisplayName -match '2008') { return 'vc2008' }
    if ($DisplayName -match '2005') { return 'vc2005' }
    return $null
}

function Resolve-VCArch {
    param([string]$DisplayName)
    if ($DisplayName -match 'x64') { return 'x64' }
    if ($DisplayName -match 'x86') { return 'x86' }
    return $null
}

# ---------- 注册表枚举（内部） ----------

function Get-RedistRegistryEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $result = @()
    foreach ($root in $roots) {
        $subkeys = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue
        foreach ($k in $subkeys) {
            $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $dn = $props.DisplayName
            if (-not $dn) { continue }
            if ($dn -notmatch 'Visual C\+\+') { continue }

            # 三分类：standard / subcomponent / thirdparty
            if ($dn -match '^Microsoft Visual C\+\+') {
                if ($dn -match 'Redistributable') { $category = 'standard' }
                else { $category = 'subcomponent' }
            } else {
                $category = 'thirdparty'
            }

            $entry = [PSCustomObject]@{
                DisplayName          = $dn
                DisplayVersion       = $props.DisplayVersion
                UninstallString      = $props.UninstallString
                QuietUninstallString = $props.QuietUninstallString
                InstallSource        = $props.InstallSource
                ProductCode          = $props.PSChildName
                Category             = $category
                IsThirdParty         = ($category -eq 'thirdparty')
                VersionId            = if ($category -eq 'standard') { Resolve-VCVersionId $dn } else { $null }
                Arch                 = if ($category -eq 'standard') { Resolve-VCArch $dn } else { $null }
            }
            $result += $entry
        }
    }
    return $result
}

# ---------- 检测 ----------

function Get-VcDetection {
    $cfg = Get-ModuleConfig -Id 'vc'
    if (-not $cfg) { throw '缺少 VC 模块配置（modules.vc）' }

    $allEntries = Get-RedistRegistryEntries
    $is64 = Test-Is64BitOS

    $standard   = @($allEntries | Where-Object { $_.Category -eq 'standard' })
    $thirdParty = @($allEntries | Where-Object { $_.Category -eq 'thirdparty' })

    $rows = @()
    foreach ($v in $cfg.versions) {
        foreach ($arch in @('x86', 'x64')) {
            if ($arch -eq 'x64' -and -not $is64) { continue }

            $installer = $v.installers.$arch
            $entries   = @($standard | Where-Object { $_.VersionId -eq $v.id -and $_.Arch -eq $arch })
            $dll       = Get-DllCheckResult -Arch $arch -Dlls $v.dlls -Mode $v.dllCheckMode -WinsxsPattern $v.winsxsPattern

            $nec = $cfg.necessityRules.$($v.necessity)
            $stateKey = $null; $stateText = $null; $stateDetail = $null

            if ($entries.Count -gt 0) {
                $versions = @($entries | ForEach-Object { $_.DisplayVersion } | Where-Object { $_ } | Sort-Object -Unique)
                if ($v.dllCheckMode -eq 'winsxs') {
                    if ($entries.Count -gt 1) { $stateKey = 'installed-multi'; $stateText = '已安装（多版本）' }
                    else { $stateKey = 'installed'; $stateText = '已安装' }
                    $stateDetail = if ($versions.Count -gt 0) { ($versions | Select-Object -Last 1) } else { $entries[0].DisplayVersion }
                    if (-not $dll.WinsxsFound) { $stateDetail += '（WinSxS 未检测到并排程序集）' }
                } else {
                    if ($dll.AllPresent) {
                        if ($entries.Count -gt 1) { $stateKey = 'installed-multi'; $stateText = '已安装（多版本）' }
                        else { $stateKey = 'installed'; $stateText = '已安装' }
                        $stateDetail = if ($versions.Count -gt 0) { ($versions | Select-Object -Last 1) } else { $entries[0].DisplayVersion }
                    } else {
                        $stateKey = 'damaged'; $stateText = '可能损坏 / 不完整'; $stateDetail = '关键 DLL 缺失：' + ($dll.Missing -join ', ')
                    }
                }
            } else {
                if ($v.dllCheckMode -eq 'winsxs') {
                    if ($dll.WinsxsFound) { $stateKey = 'residual'; $stateText = '残留'; $stateDetail = 'WinSxS 存在并排组件，但无卸载项（其他程序私装 / 残留）' }
                    else { $stateKey = 'notinstalled'; $stateText = '未安装'; $stateDetail = $null }
                } else {
                    if ($dll.AnyPresent) { $stateKey = 'residual'; $stateText = '残留'; $stateDetail = 'DLL 存在但无卸载项：' + (($dll.Present | ForEach-Object { $_.Dll }) -join ', ') }
                    else { $stateKey = 'notinstalled'; $stateText = '未安装'; $stateDetail = $null }
                }
            }

            $rows += [PSCustomObject]@{
                Id              = $v.id
                Arch            = $arch
                DisplayName     = $v.name
                InternalVersion = $v.internalVersion
                Necessity       = $v.necessity
                NecessityLabel  = $nec.label
                NecessityColor  = $nec.color
                NecessityReason = $nec.reason
                Note            = $v.note
                StateKey        = $stateKey
                StateText       = $stateText
                StateDetail     = $stateDetail
                Versions        = @($versions)
                Entries         = $entries
                DllCheck        = $dll
                Installer       = $installer
                Selected        = ($nec.defaultChecked -eq $true)
            }
        }
    }

    $total     = $rows.Count
    $installed = @($rows | Where-Object { $_.StateKey -in @('installed', 'installed-multi') }).Count
    $damaged   = @($rows | Where-Object { $_.StateKey -eq 'damaged' }).Count
    $missing   = @($rows | Where-Object { $_.StateKey -eq 'notinstalled' }).Count
    $residual  = @($rows | Where-Object { $_.StateKey -eq 'residual' }).Count

    return [PSCustomObject]@{
        Rows    = $rows
        Summary = [PSCustomObject]@{ Total = $total; Installed = $installed; Damaged = $damaged; Missing = $missing; Residual = $residual }
        Extra   = [PSCustomObject]@{ ThirdParty = $thirdParty }
    }
}

# ---------- 安装 / 卸载（后台执行，写 Sync，返回结果数组） ----------

function Invoke-VcAction {
    param(
        [string]$Operation,
        $Rows,
        [hashtable]$Sync
    )
    $results = @()

    switch ($Operation) {
        'install' {
            foreach ($r in @($Rows)) {
                $name = ('{0} {1}' -f $r.DisplayName, $r.Arch)
                $Sync.LogLines += ('== 安装 {0} ==' -f $name) + "`r`n"
                try {
                    $inst = $r.Installer
                    $dest = Join-Path (Get-DownloadDirectory) $inst.fileName
                    $Sync.StatusText = ('正在下载 {0} ...' -f $name)
                    Start-RedistDownload -Url $inst.url -DestPath $dest -Sync $Sync | Out-Null
                    $Sync.StatusText = ('正在校验 {0}（数字签名 / SHA256）...' -f $name)
                    $chk = Test-RedistPackage -Path $dest -ExpectedSha256 ([string]$inst.sha256)
                    if (-not $chk.Passed) { throw ('校验失败：签名={0} 哈希={1}' -f $chk.SignatureOk, $chk.HashOk) }
                    $Sync.LogLines += ('  下载完成：{0}（签名：{1}）' -f (Format-Bytes (Get-Item $dest).Length), $chk.SignatureOk) + "`r`n"
                    $Sync.StatusText = ('正在静默安装 {0}（将弹出 UAC 提权）...' -f $name)
                    $code = Invoke-ElevatedProcess -FilePath $dest -ArgumentList @($inst.installArgs)
                    if (Test-ExitSuccess $code) {
                        $Sync.LogLines += ('  完成（退出码 {0}）' -f $code) + "`r`n"
                        $results += ('✓ {0}（退出码 {1}）' -f $name, $code)
                        Write-RedistLog -Message ('安装成功：{0}（退出码 {1}）' -f $name, $code) -Level INFO
                    } else {
                        $Sync.LogLines += ('  返回退出码 {0}（安装可能未成功）' -f $code) + "`r`n"
                        $results += ('✗ {0}（退出码 {1}）' -f $name, $code)
                        Write-RedistLog -Message ('安装未成功：{0}（退出码 {1}）' -f $name, $code) -Level WARN
                    }
                } catch {
                    $Sync.LogLines += ('  失败：{0}' -f $_.Exception.Message) + "`r`n"
                    $results += ('✗ {0}：{1}' -f $name, $_.Exception.Message)
                    Write-RedistLog -Message ('安装失败：{0}：{1}' -f $name, $_.Exception.Message) -Level ERROR
                }
                $Sync.ProgressPercent = 0
                if ($Sync.CancelRequested) { $results += '⚠ 已取消'; break }
            }
        }

        'uninstall' {
            foreach ($r in @($Rows)) {
                $name = ('{0} {1}' -f $r.DisplayName, $r.Arch)
                if ($r.Entries.Count -eq 0) {
                    $Sync.LogLines += ('== {0}：无卸载项，跳过 ==' -f $name) + "`r`n"
                    continue
                }
                $Sync.LogLines += ('== 卸载 {0}（{1} 个子版本）==' -f $name, $r.Entries.Count) + "`r`n"
                foreach ($entry in $r.Entries) {
                    try {
                        $Sync.StatusText = ('正在卸载 {0}（{1}）...' -f $name, $entry.DisplayVersion)
                        $r2 = Uninstall-Redist $entry
                        if (Test-ExitSuccess $r2.ExitCode) {
                            $Sync.LogLines += ('  ✓ {0}（退出码 {1}）' -f $entry.DisplayVersion, $r2.ExitCode) + "`r`n"
                            $results += ('✓ {0} {1}' -f $name, $entry.DisplayVersion)
                            Write-RedistLog -Message ('卸载成功：{0} {1}（退出码 {2}）' -f $name, $entry.DisplayVersion, $r2.ExitCode) -Level INFO
                        } else {
                            $Sync.LogLines += ('  ✗ {0}：退出码 {1}（卸载可能未成功）' -f $entry.DisplayVersion, $r2.ExitCode) + "`r`n"
                            $results += ('✗ {0} {1}（退出码 {2}）' -f $name, $entry.DisplayVersion, $r2.ExitCode)
                            Write-RedistLog -Message ('卸载未成功：{0} {1}（退出码 {2}）' -f $name, $entry.DisplayVersion, $r2.ExitCode) -Level WARN
                        }
                    } catch {
                        $Sync.LogLines += ('  ✗ {0}：{1}' -f $entry.DisplayVersion, $_.Exception.Message) + "`r`n"
                        $results += ('✗ {0} {1}：{2}' -f $name, $entry.DisplayVersion, $_.Exception.Message)
                        Write-RedistLog -Message ('卸载失败：{0} {1}：{2}' -f $name, $entry.DisplayVersion, $_.Exception.Message) -Level ERROR
                    }
                }
            }
        }
    }

    return $results
}

# ---------- 卸载命令解析（内部） ----------

function Resolve-RedistUninstall {
    param($Entry)
    $us  = $Entry.UninstallString
    $qus = $Entry.QuietUninstallString

    if ($us -match 'MsiExec') {
        $code = $null
        if ($us -match '\{[0-9A-Fa-f-]{36}\}') { $code = $matches[0] }
        elseif ($Entry.ProductCode -and $Entry.ProductCode -match '\{[0-9A-Fa-f-]{36}\}') { $code = $Entry.ProductCode }
        return [PSCustomObject]@{
            Type        = 'MSI'
            ProductCode = $code
            ExePath     = $null
            Args        = @(('/X{0}' -f $code), '/qn', '/norestart')
        }
    }

    $exe = $null
    if ($qus -and $qus -match '"([^"]+\.exe)"') { $exe = $matches[1] }
    elseif ($us -and $us -match '"([^"]+\.exe)"') { $exe = $matches[1] }
    elseif ($us -and $us -match '([A-Za-z]:\\[^\s]+\.exe)') { $exe = $matches[1] }

    return [PSCustomObject]@{
        Type        = 'Burn'
        ProductCode = $null
        ExePath     = $exe
        Args        = @('/uninstall', '/quiet', '/norestart')
    }
}

function Uninstall-Redist {
    param($Entry)
    $cmd = Resolve-RedistUninstall $Entry

    if ($cmd.Type -eq 'MSI') {
        if (-not $cmd.ProductCode) {
            throw ('无法解析 ProductCode，卸载中止（DisplayName={0}）' -f $Entry.DisplayName)
        }
        $code = Invoke-ElevatedProcess -FilePath 'msiexec.exe' -ArgumentList $cmd.Args
        return [PSCustomObject]@{ Type = 'MSI'; ExitCode = $code; Note = '' }
    } else {
        if (-not $cmd.ExePath) {
            throw ('无法解析卸载引导程序路径，卸载中止（DisplayName={0}）' -f $Entry.DisplayName)
        }
        $cacheMissing = -not (Test-Path -LiteralPath $cmd.ExePath)
        if ($cacheMissing) {
            throw ('Package Cache 中的卸载程序已缺失：{0}。请先重新下载对应官方安装包后再卸载。' -f $cmd.ExePath)
        }
        $code = Invoke-ElevatedProcess -FilePath $cmd.ExePath -ArgumentList $cmd.Args
        return [PSCustomObject]@{ Type = 'Burn'; ExitCode = $code; Note = '' }
    }
}

# ---------- 诊断报告片段 ----------

function Get-VcReport {
    param($Detection)
    $sb = New-Object System.Text.StringBuilder

    $null = $sb.AppendLine('【总体情况】')
    $null = $sb.AppendLine(('  已安装：{0} / {1}' -f $Detection.Summary.Installed, $Detection.Summary.Total))
    $null = $sb.AppendLine(('  可能损坏：{0}' -f $Detection.Summary.Damaged))
    $null = $sb.AppendLine(('  未安装：{0}' -f $Detection.Summary.Missing))
    $null = $sb.AppendLine(('  残留：{0}' -f $Detection.Summary.Residual))
    $null = $sb.AppendLine('')

    $null = $sb.AppendLine('【明细】')
    foreach ($r in $Detection.Rows) {
        $line = '  [{0}] {1} {2}（内部 {3}）' -f $r.StateText, $r.DisplayName, $r.Arch, $r.InternalVersion
        if ($r.StateDetail) { $line += ' —— ' + $r.StateDetail }
        $null = $sb.AppendLine($line)
    }

    $tp = @($Detection.Extra.ThirdParty)
    if ($tp.Count -gt 0) {
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('【第三方捆绑运行库】（不纳入安装 / 卸载目标）')
        foreach ($t in $tp) {
            $null = $sb.AppendLine(('  - {0}（{1}）' -f $t.DisplayName, $t.DisplayVersion))
        }
    }

    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('【建议操作】')
    $suggested = $false
    foreach ($r in $Detection.Rows) {
        if ($r.StateKey -eq 'damaged') {
            $null = $sb.AppendLine(('  - 覆盖重装修复损坏：{0} {1}' -f $r.DisplayName, $r.Arch))
            $suggested = $true
        }
    }
    foreach ($r in $Detection.Rows) {
        if ($r.StateKey -eq 'notinstalled') {
            $null = $sb.AppendLine(('  - 安装：{0} {1}（{2}）' -f $r.DisplayName, $r.Arch, $r.NecessityLabel))
            $suggested = $true
        }
    }
    if (-not $suggested) {
        $null = $sb.AppendLine('  - VC 运行库状态正常，无需操作。')
    }

    return $sb.ToString()
}

Export-ModuleMember -Function Get-VcManifest, Get-VcDetection, Invoke-VcAction, Get-VcReport
