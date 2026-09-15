# ============================================================
#  VCRedistManager.ps1
#  运行库管理工具 —— 主程序（WPF GUI 入口，模块无关）
#
#  依赖：
#    · VCRedistManager.Core.psm1（共享基础设施 + 模块注册表 / 分发）
#    · Modules\*.psm1（具体运行库模块，按「模块契约」实现）
#    · config.json（顶层共享配置 + modules.{id} 各模块配置）
#
#  本文件不写死任何具体运行库——页签 / 检测 / 安装 / 卸载 / 修复 /
#  诊断报告均由模块注册表驱动。新增模块只需在 Modules\ 下加一个 .psm1。
#
#  本文件必须保存为 UTF-8 with BOM（见 README）。
#  启动：powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\VCRedistManager.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

# ---------- STA 守护（WPF 需要 STA 线程） ----------
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $cmd = ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cmd
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModulePath = Join-Path $script:ScriptDir 'VCRedistManager.Core.psm1'
$script:ConfigPath = Join-Path $script:ScriptDir 'config.json'
$script:ModulesDir = Join-Path $script:ScriptDir 'Modules'

Import-Module $script:ModulePath -Force
Initialize-VCRedistConfig -ConfigPath $script:ConfigPath | Out-Null
Initialize-VCRedistModules -ModulesDir $script:ModulesDir | Out-Null
$loadedModules = (@(Get-VCRedistModules) | ForEach-Object { $_.Title }) -join '、'
Write-VCRedistLog -Message ('==== 程序启动（版本 {0}）====' -f (Get-VCRedistConfig).appVersion) -Level INFO
Write-VCRedistLog -Message ('已加载模块：{0}' -f $loadedModules) -Level INFO

# ---------- 共享状态 ----------
$script:sync = [hashtable]::Synchronized(@{
    Busy            = $false
    Operation       = ''
    ModuleId        = $null
    Payload         = $null
    Result          = $null
    LastError       = $null
    StatusText      = '就绪'
    ProgressPercent = 0
    IsIndeterminate = $false
    LogLines        = ''
    CancelRequested = $false
})
$script:LastBusy       = $false
$script:AllDetection   = $null
$script:NotifyDetect   = $false
$script:SelectionState = @{}
$script:WorkerRunspace = $null
$script:WorkerPs       = $null
$script:LastLog        = $null

# ---------- 后台工作脚本（运行于独立 Runspace，仅做薄分发） ----------
$workerScript = @'
param($Sync, $ModulePath, $ConfigPath, $ModulesDir)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
Initialize-VCRedistConfig -ConfigPath $ConfigPath | Out-Null
Initialize-VCRedistModules -ModulesDir $ModulesDir | Out-Null

try {
    switch ($Sync.Operation) {
        'detect' {
            $Sync.StatusText = '正在检测...'
            $Sync.IsIndeterminate = $true
            $Sync.Result = Get-AllModuleDetection
        }
        'install' {
            $Sync.Result = Invoke-AllModuleActions -Operation 'install' -Rows $Sync.Payload -Sync $Sync
        }
        'uninstall' {
            $Sync.Result = Invoke-AllModuleActions -Operation 'uninstall' -Rows $Sync.Payload -Sync $Sync
        }
        'repair' {
            $Sync.Result = Invoke-ModuleOperation -ModuleId $Sync.ModuleId -Operation 'repair' -Rows $Sync.Payload -Sync $Sync
        }
    }
} catch {
    $Sync.LastError = $_.Exception.Message
    $Sync.LogLines += ('【错误】{0}' -f $_.Exception.Message) + "`r`n"
    Write-VCRedistLog -Message ('后台操作异常：{0}' -f $_.Exception.Message) -Level ERROR
} finally {
    $Sync.IsIndeterminate = $false
    $Sync.ProgressPercent = 0
    $Sync.Busy = $false
}
'@

# ---------- XAML 模板：Table 模块页签（逐行可操作） ----------
function Get-TableTabXaml {
    param($m)
    $id       = $m.Id
    $title    = $m.Title
    $gridName = "Grid_$id"
    return @"
        <TabItem Header="$title">
            <DataGrid x:Name="$gridName" IsReadOnly="True" AutoGenerateColumns="False"
                      CanUserAddRows="False" CanUserDeleteRows="False" HeadersVisibility="Column"
                      GridLinesVisibility="Horizontal" RowHeight="34" Background="#FFFFFF"
                      SelectionMode="Single">
                <DataGrid.Columns>
                    <DataGridTemplateColumn Header="勾选" Width="46">
                        <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                                <CheckBox IsChecked="{Binding Selected, Mode=OneWay}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                    <DataGridTextColumn Header="版本名称" Binding="{Binding DisplayName}" Width="120"/>
                    <DataGridTextColumn Header="架构" Binding="{Binding Arch}" Width="52">
                        <DataGridTextColumn.ElementStyle>
                            <Style TargetType="TextBlock">
                                <Setter Property="HorizontalAlignment" Value="Center"/>
                            </Style>
                        </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="内部版本" Binding="{Binding InternalVersion}" Width="80">
                        <DataGridTextColumn.ElementStyle>
                            <Style TargetType="TextBlock">
                                <Setter Property="HorizontalAlignment" Value="Center"/>
                                <Setter Property="Foreground" Value="#666666"/>
                            </Style>
                        </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="状态" Binding="{Binding StateText}" Width="165">
                        <DataGridTextColumn.CellStyle>
                            <Style TargetType="DataGridCell">
                                <Setter Property="ToolTip" Value="{Binding StateDetail}"/>
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding StateKey}" Value="installed">
                                        <Setter Property="Foreground" Value="#2E7D32"/>
                                        <Setter Property="FontWeight" Value="SemiBold"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StateKey}" Value="installed-multi">
                                        <Setter Property="Foreground" Value="#2E7D32"/>
                                        <Setter Property="FontWeight" Value="SemiBold"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StateKey}" Value="damaged">
                                        <Setter Property="Foreground" Value="#C62828"/>
                                        <Setter Property="FontWeight" Value="Bold"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StateKey}" Value="notinstalled">
                                        <Setter Property="Foreground" Value="#9E9E9E"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding StateKey}" Value="residual">
                                        <Setter Property="Foreground" Value="#E65100"/>
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </DataGridTextColumn.CellStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="必要性" Binding="{Binding NecessityLabel}" Width="80">
                        <DataGridTextColumn.CellStyle>
                            <Style TargetType="DataGridCell">
                                <Setter Property="ToolTip" Value="{Binding NecessityReason}"/>
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding Necessity}" Value="required">
                                        <Setter Property="Foreground" Value="#2E7D32"/>
                                        <Setter Property="FontWeight" Value="Bold"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding Necessity}" Value="optional">
                                        <Setter Property="Foreground" Value="#1565C0"/>
                                    </DataTrigger>
                                    <DataTrigger Binding="{Binding Necessity}" Value="notRecommended">
                                        <Setter Property="Foreground" Value="#C62828"/>
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </DataGridTextColumn.CellStyle>
                    </DataGridTextColumn>
                    <DataGridTemplateColumn Header="操作" Width="228">
                        <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                    <Button Content="安装" Tag="install" Padding="8,2" Margin="0,0,4,0"/>
                                    <Button Content="卸载" Tag="uninstall" Padding="8,2" Margin="0,0,4,0"/>
                                    <Button Content="检查" Tag="check" Padding="8,2"/>
                                </StackPanel>
                            </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                </DataGrid.Columns>
            </DataGrid>
        </TabItem>
"@
}

# ---------- XAML 模板：List 模块页签（只读列表 + 检测 / 修复） ----------
function Get-ListTabXaml {
    param($m)
    $id         = $m.Id
    $title      = $m.Title
    $gridName   = "Grid_$id"
    $statusName = "StatusText_$id"
    $checkName  = "CheckBtn_$id"
    $repairName = "RepairBtn_$id"
    return @"
        <TabItem Header="$title">
            <Grid Margin="8">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
                    <TextBlock Text="组件状态" FontWeight="SemiBold" Foreground="#333333" VerticalAlignment="Center"/>
                    <TextBlock x:Name="$statusName" Text="未检测" Foreground="#9E9E9E" VerticalAlignment="Center" Margin="12,0,0,0"/>
                    <Button x:Name="$checkName" Content="检测" Padding="10,3" Margin="16,0,0,0"/>
                    <Button x:Name="$repairName" Content="修复" Padding="10,3" Margin="6,0,0,0"/>
                </StackPanel>
                <DataGrid x:Name="$gridName" Grid.Row="1" IsReadOnly="True" AutoGenerateColumns="False"
                          CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                          RowHeight="30" Background="#FFFFFF" BorderBrush="#E0E0E0" BorderThickness="1">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="组件（DLL）" Binding="{Binding Name}" Width="220"/>
                        <DataGridTextColumn Header="归属" Binding="{Binding Category}" Width="240"/>
                        <DataGridTextColumn Header="状态" Binding="{Binding StateText}" Width="90">
                            <DataGridTextColumn.CellStyle>
                                <Style TargetType="DataGridCell">
                                    <Style.Triggers>
                                        <DataTrigger Binding="{Binding StateKey}" Value="installed">
                                            <Setter Property="Foreground" Value="#2E7D32"/>
                                            <Setter Property="FontWeight" Value="SemiBold"/>
                                        </DataTrigger>
                                        <DataTrigger Binding="{Binding StateKey}" Value="missing">
                                            <Setter Property="Foreground" Value="#C62828"/>
                                        </DataTrigger>
                                    </Style.Triggers>
                                </Style>
                            </DataGridTextColumn.CellStyle>
                        </DataGridTextColumn>
                        <DataGridTextColumn Header="版本 / 说明" Binding="{Binding Detail}" Width="*"/>
                    </DataGrid.Columns>
                </DataGrid>
            </Grid>
        </TabItem>
"@
}

# ---------- 组装完整 XAML ----------
$tabItemsXaml = ''
foreach ($m in (Get-VCRedistModules)) {
    if ($m.Kind -eq 'Table') { $tabItemsXaml += Get-TableTabXaml $m }
    else { $tabItemsXaml += Get-ListTabXaml $m }
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="运行库管理工具" Height="680" Width="980"
        WindowStartupLocation="CenterScreen" Background="#F5F6F8"
        FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- 汇总条 -->
        <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#E0E0E0" BorderThickness="1" CornerRadius="4" Padding="12,8" Margin="0,0,0,8">
            <TextBlock x:Name="SummaryText" Text="正在初始化检测..." FontSize="14" Foreground="#333333" TextWrapping="Wrap"/>
        </Border>

        <!-- 工具栏 -->
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,8">
            <Button x:Name="CheckAllBtn" Content="🔍 检查全部" Padding="12,5" Margin="0,0,6,0" FontWeight="SemiBold"/>
            <Button x:Name="InstallRecommendedBtn" Content="⭐ 一键安装推荐项" Padding="12,5" Margin="0,0,6,0" FontWeight="SemiBold"/>
            <Button x:Name="InstallSelectedBtn" Content="⬇ 安装勾选项" Padding="12,5" Margin="0,0,6,0"/>
            <Button x:Name="UninstallSelectedBtn" Content="🗑 卸载勾选项" Padding="12,5" Margin="0,0,6,0"/>
            <Button x:Name="CopyReportBtn" Content="📋 复制诊断报告" Padding="12,5" Margin="0,0,6,0"/>
            <Button x:Name="ClearCacheBtn" Content="🧹 清理缓存" Padding="12,5" Margin="0,0,6,0"/>
            <Button x:Name="OpenLogBtn" Content="📄 打开日志" Padding="12,5"/>
        </StackPanel>

        <!-- 主内容：由模块注册表动态生成的页签 -->
        <TabControl x:Name="MainTabs" Grid.Row="2" Background="#FFFFFF" BorderBrush="#E0E0E0" BorderThickness="1">
$tabItemsXaml
        </TabControl>

        <!-- 进度 -->
        <Grid Grid.Row="3" Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="StatusText" Text="就绪" Foreground="#555555" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ProgressBar x:Name="ProgressBar" Grid.Column="1" Height="18" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center"/>
            <Button x:Name="CancelBtn" Grid.Column="2" Content="取消" Padding="10,2" Margin="8,0,0,0" IsEnabled="False"/>
        </Grid>

        <!-- 日志 / 报告 -->
        <TextBox x:Name="LogBox" Grid.Row="4" Height="130" Margin="0,8,0,0" IsReadOnly="True"
                 TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 Background="#FFFFFF" BorderBrush="#E0E0E0" BorderThickness="1"
                 FontFamily="Consolas, Microsoft YaHei UI" FontSize="12"/>

        <TextBlock Grid.Row="5" Text="只从微软官方源下载，安装包经 Authenticode 数字签名 + SHA256 校验后才执行。安装 / 卸载需管理员权限（UAC）。"
                   Foreground="#999999" FontSize="11" Margin="0,4,0,0"/>
    </Grid>
</Window>
"@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)

function Find-Element([string]$name) { return $window.FindName($name) }

$SummaryText            = Find-Element 'SummaryText'
$StatusText             = Find-Element 'StatusText'
$ProgressBar            = Find-Element 'ProgressBar'
$LogBox                 = Find-Element 'LogBox'
$CheckAllBtn            = Find-Element 'CheckAllBtn'
$InstallRecommendedBtn  = Find-Element 'InstallRecommendedBtn'
$InstallSelectedBtn     = Find-Element 'InstallSelectedBtn'
$UninstallSelectedBtn   = Find-Element 'UninstallSelectedBtn'
$CopyReportBtn          = Find-Element 'CopyReportBtn'
$ClearCacheBtn          = Find-Element 'ClearCacheBtn'
$OpenLogBtn             = Find-Element 'OpenLogBtn'
$CancelBtn              = Find-Element 'CancelBtn'

# ---------- 后台任务启动 ----------
function Start-Operation {
    param([string]$Operation, $Payload, [string]$ModuleId = $null)
    if ($script:sync.Busy) { return }
    if ($script:WorkerRunspace) { try { $script:WorkerRunspace.Dispose() } catch { } }

    $script:sync.Busy = $true
    $script:sync.Operation = $Operation
    $script:sync.ModuleId = $ModuleId
    $script:sync.Payload = $Payload
    $script:sync.Result = $null
    $script:sync.LastError = $null
    $script:sync.LogLines = ''
    $script:sync.ProgressPercent = 0
    $script:sync.IsIndeterminate = $false
    $script:sync.CancelRequested = $false
    $script:sync.StatusText = '准备中...'
    $script:LastBusy = $false
    $CancelBtn.IsEnabled = ($Operation -eq 'install')
    Write-VCRedistLog -Message ('开始操作：{0}' -f $Operation) -Level INFO

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($workerScript)
        $null = $ps.AddArgument($script:sync)
        $null = $ps.AddArgument($script:ModulePath)
        $null = $ps.AddArgument($script:ConfigPath)
        $null = $ps.AddArgument($script:ModulesDir)
        $null = $ps.BeginInvoke()
        $script:WorkerRunspace = $rs
        $script:WorkerPs = $ps
    } catch {
        $script:sync.Busy = $false
        $script:sync.StatusText = '操作启动失败'
        $CancelBtn.IsEnabled = $false
        [System.Windows.MessageBox]::Show(('后台任务启动失败：' + $_.Exception.Message), '错误', 'OK', 'Error') | Out-Null
    }
}

# ---------- UI 刷新 ----------
function Get-RowKey {
    param($Row)
    return ('{0}|{1}|{2}' -f $Row.ModuleId, $Row.Id, $Row.Arch)
}

function Get-AllTableRows {
    $rows = @()
    foreach ($d in @($script:AllDetection)) {
        if ($d.Kind -eq 'Table') { $rows += @($d.Result.Rows) }
    }
    return $rows
}

function Build-SummaryText {
    param($AllDetection)
    if (-not $AllDetection) { return '正在初始化检测...' }
    $parts = @()
    foreach ($d in @($AllDetection)) {
        if ($d.Kind -eq 'Table') {
            $s  = $d.Result.Summary
            $tp = @($d.Result.Extra.ThirdParty)
            $parts += ('{0}：已安装 {1}/{2} · 损坏 {3} · 未安装 {4} · 残留 {5} · 第三方 {6}' -f $d.Title, $s.Installed, $s.Total, $s.Damaged, $s.Missing, $s.Residual, $tp.Count)
        } else {
            $s = $d.Result.Summary
            $parts += ('{0}：{1}' -f $d.Title, $s.StateText)
        }
    }
    return ($parts -join '　|　')
}

function Update-ListModule {
    param([string]$ModuleId, $Detection)
    $statusText = Find-Element ("StatusText_" + $ModuleId)
    $grid       = Find-Element ("Grid_" + $ModuleId)
    $s = $Detection.Summary
    $ready = @($Detection.Rows | Where-Object { $_.StateKey -eq 'installed' }).Count
    $total = @($Detection.Rows).Count
    $statusText.Text = ('{0}（{1}/{2} 组件就绪）' -f $s.StateText, $ready, $total)
    switch ($s.StateKey) {
        'ok'      { $statusText.Foreground = [System.Windows.Media.Brushes]::Green }
        'partial' { $statusText.Foreground = [System.Windows.Media.Brushes]::OrangeRed }
        'missing' { $statusText.Foreground = [System.Windows.Media.Brushes]::Red }
        default   { $statusText.Foreground = [System.Windows.Media.Brushes]::Gray }
    }
    $statusText.ToolTip = $s.StateDetail
    $grid.ItemsSource = $null
    $grid.ItemsSource = $Detection.Rows
}

function Update-AllModuleDetection {
    param($AllDetection)
    $script:AllDetection = $AllDetection
    foreach ($d in @($AllDetection)) {
        if ($d.Kind -eq 'Table') {
            $grid = Find-Element ("Grid_" + $d.Id)
            foreach ($r in $d.Result.Rows) {
                $key = Get-RowKey $r
                if ($script:SelectionState.ContainsKey($key)) { $r.Selected = $script:SelectionState[$key] }
            }
            $grid.ItemsSource = $null
            $grid.ItemsSource = $d.Result.Rows
        } else {
            Update-ListModule -ModuleId $d.Id -Detection $d.Result
        }
    }
    $SummaryText.Text = Build-SummaryText $AllDetection
}

function RefreshCheckboxDisplay {
    foreach ($d in @($script:AllDetection)) {
        if ($d.Kind -eq 'Table') {
            $grid = Find-Element ("Grid_" + $d.Id)
            $grid.ItemsSource = $null
            $grid.ItemsSource = $d.Result.Rows
        }
    }
}

# ---------- 操作入口（UI 线程） ----------
function Start-Detect {
    Start-Operation -Operation 'detect' -Payload $null
}

function Get-RowActionDescription {
    param($r)
    switch ($r.StateKey) {
        'installed'       { return '已安装 → 覆盖重装' }
        'installed-multi' { return '已安装(多版本) → 覆盖重装' }
        'damaged'         { return '可能损坏 → 覆盖重装修复' }
        'residual'        { return '残留 → 全新安装' }
        default           { return '未安装 → 全新安装' }
    }
}

function Start-Install {
    param([object[]]$Rows)
    if ($script:sync.Busy) { return }
    if (-not $Rows -or $Rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('请先勾选或点击要安装的项', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $rows = @($Rows)
    $lines = ($rows | ForEach-Object { ('  {0} {1}  [{2}]' -f $_.DisplayName, $_.Arch, (Get-RowActionDescription $_)) }) -join "`r`n"

    $notRec = @($rows | Where-Object { $_.Necessity -eq 'notRecommended' })
    if ($notRec.Count -gt 0) {
        $msg = ('以下项被标记为「不推荐」（仅极少数遗留软件需要，存在历史安全隐患），确定仍要安装？' + "`r`n" + `
                (($notRec | ForEach-Object { ('  {0} {1}' -f $_.DisplayName, $_.Arch) }) -join '、'))
        $r = [System.Windows.MessageBox]::Show($msg, '确认安装（不推荐项）', 'YesNo', 'Warning')
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    } else {
        $r = [System.Windows.MessageBox]::Show(('即将从微软官方源下载并静默安装：' + "`r`n`r`n" + $lines + "`r`n`r`n" + '（安装过程中会弹出 UAC 提权）'), '确认安装', 'YesNo', 'Information')
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    Start-Operation -Operation 'install' -Payload $rows
}

function Start-Uninstall {
    param([object[]]$Rows)
    if ($script:sync.Busy) { return }
    $rows = @($Rows | Where-Object { $_.Entries.Count -gt 0 })
    if ($rows.Count -eq 0) {
        [System.Windows.MessageBox]::Show('所选项目前没有可卸载的已安装项', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $lines = ($rows | ForEach-Object { ('  {0} {1}（{2} 个子版本）' -f $_.DisplayName, $_.Arch, $_.Entries.Count) }) -join "`r`n"
    $r = [System.Windows.MessageBox]::Show(('确定卸载以下运行库？' + "`r`n" + $lines + "`r`n`r`n" + '⚠ 卸载可能影响依赖该运行库的软件！' + "`r`n`r`n" + '（卸载过程中会弹出 UAC 提权）'), '确认卸载（破坏性操作）', 'YesNo', 'Warning')
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Start-Operation -Operation 'uninstall' -Payload $rows
}

function Start-InstallRecommended {
    if ($script:sync.Busy) { return }
    if (-not $script:AllDetection) { Start-Detect; return }
    $targets = @(Get-AllTableRows | Where-Object { $_.Necessity -eq 'required' -and $_.StateKey -in @('notinstalled', 'damaged') })
    if ($targets.Count -eq 0) {
        [System.Windows.MessageBox]::Show('所有「必要」运行库均已安装，无需操作', '提示', 'OK', 'Information') | Out-Null
        return
    }
    foreach ($t in $targets) {
        $t.Selected = $true
        $script:SelectionState[(Get-RowKey $t)] = $true
    }
    RefreshCheckboxDisplay
    Start-Install -Rows $targets
}

function Build-Report {
    param($AllDetection)
    $sb = New-Object System.Text.StringBuilder
    $cfg = Get-VCRedistConfig
    $null = $sb.AppendLine('============================================')
    $null = $sb.AppendLine(('  {0} · 诊断报告' -f $cfg.appName))
    $null = $sb.AppendLine('============================================')
    $null = $sb.AppendLine(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $null = $sb.AppendLine(('系统架构：{0}' -f $(if (Test-Is64BitOS) { 'x64' } else { 'x86' })))
    $null = $sb.AppendLine('')

    foreach ($d in @($AllDetection)) {
        $m = Get-VCRedistModule -Id $d.Id
        $null = $sb.AppendLine(('【{0}】' -f $d.Title))
        $body = (& $m.ReportFn -Detection $d.Result).TrimEnd()
        foreach ($line in ($body -split '\r?\n')) {
            $null = $sb.AppendLine(('  ' + $line))
        }
        $null = $sb.AppendLine('')
    }
    return $sb.ToString()
}

function Copy-Report {
    if (-not $script:AllDetection) { return }
    $report = Build-Report $script:AllDetection
    $LogBox.Text = $report
    $LogBox.ScrollToEnd()
    try {
        [System.Windows.Clipboard]::SetText($report)
        [System.Windows.MessageBox]::Show('诊断报告已复制到剪贴板', '完成', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show('报告已显示在下方日志区，但复制到剪贴板失败：' + $_.Exception.Message, '提示', 'OK', 'Warning') | Out-Null
    }
}

function Clear-Cache {
    try {
        $r = Clear-VCRedistCache
        $freed = Format-Bytes $r.FreedBytes
        [System.Windows.MessageBox]::Show(('已清理 {0} 个缓存文件，释放 {1}' -f $r.RemovedCount, $freed), '清理缓存', 'OK', 'Information') | Out-Null
        Write-VCRedistLog -Message ('清理缓存：{0} 个文件，释放 {1}' -f $r.RemovedCount, $freed) -Level INFO
    } catch {
        [System.Windows.MessageBox]::Show(('清理失败：' + $_.Exception.Message), '错误', 'OK', 'Error') | Out-Null
        Write-VCRedistLog -Message ('清理缓存失败：{0}' -f $_.Exception.Message) -Level ERROR
    }
}

function Start-ListCheck {
    param([string]$ModuleId)
    if ($script:sync.Busy) { return }
    $m = Get-VCRedistModule -Id $ModuleId
    try {
        $det = & $m.DetectFn
        Update-ListModule -ModuleId $ModuleId -Detection $det
        if ($script:AllDetection) {
            foreach ($d in @($script:AllDetection)) {
                if ($d.Id -eq $ModuleId) { $d.Result = $det }
            }
            $SummaryText.Text = Build-SummaryText $script:AllDetection
        }
        $s = $det.Summary
        Write-VCRedistLog -Message ('{0} 检测：{1}' -f $m.Title, $s.StateDetail) -Level INFO
        if ($s.StateKey -eq 'ok') {
            [System.Windows.MessageBox]::Show(('✅ {0} 组件均已就绪，无需修复。' -f $m.Title), ('{0} 检测成功' -f $m.Title), 'OK', 'Information') | Out-Null
        } else {
            [System.Windows.MessageBox]::Show(('{0} 组件缺失：' -f $m.Title) + "`r`n`r`n" + $s.StateDetail + "`r`n`r`n" + '可点击「修复」从微软官方源下载并安装。', ('{0} 需要修复' -f $m.Title), 'OK', 'Warning') | Out-Null
        }
    } catch {
        [System.Windows.MessageBox]::Show(('检测失败：' + $_.Exception.Message), '错误', 'OK', 'Error') | Out-Null
        Write-VCRedistLog -Message ('{0} 检测失败：{1}' -f $m.Title, $_.Exception.Message) -Level ERROR
    }
}

function Start-ListRepair {
    param([string]$ModuleId)
    if ($script:sync.Busy) { return }
    $m = Get-VCRedistModule -Id $ModuleId
    $r = [System.Windows.MessageBox]::Show(('将修复 {0}：从官方源下载并静默安装（期间会弹出 UAC 提权）。确定继续？' -f $m.Title), ('确认修复 {0}' -f $m.Title), 'YesNo', 'Information')
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Start-Operation -Operation 'repair' -Payload $null -ModuleId $ModuleId
}

function Open-Log {
    $path = Get-VCRedistLogPath
    if (Test-Path -LiteralPath $path) {
        try {
            Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $path)
        } catch {
            Start-Process -FilePath $path
        }
    } else {
        [System.Windows.MessageBox]::Show('日志文件尚不存在（执行操作后会自动生成）。', '提示', 'OK', 'Information') | Out-Null
    }
}

# ---------- 事件绑定 ----------
function Find-AncestorControl {
    param($Source, [type]$TargetType)
    $cur = $Source
    while ($cur -ne $null) {
        if ($cur -is $TargetType) { return $cur }
        try { $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur) } catch { return $null }
    }
    return $null
}

$CheckAllBtn.Add_Click({ $script:NotifyDetect = $true; Start-Detect })
$InstallRecommendedBtn.Add_Click({ Start-InstallRecommended })
$InstallSelectedBtn.Add_Click({ Start-Install -Rows @(Get-AllTableRows | Where-Object { $_.Selected }) })
$UninstallSelectedBtn.Add_Click({ Start-Uninstall -Rows @(Get-AllTableRows | Where-Object { $_.Selected }) })
$CopyReportBtn.Add_Click({ Copy-Report })
$ClearCacheBtn.Add_Click({ Clear-Cache })
$OpenLogBtn.Add_Click({ Open-Log })
$CancelBtn.Add_Click({ $script:sync.CancelRequested = $true })

# 各 Table 模块：行内按钮 / 勾选框（按模块网格逐一绑定，运行时用 DataContext 里的 ModuleId 分发）
foreach ($m in (Get-VCRedistModules)) {
    if ($m.Kind -ne 'Table') { continue }
    $grid = Find-Element ("Grid_" + $m.Id)

    $grid.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $btn = Find-AncestorControl -Source $e.OriginalSource -TargetType ([System.Windows.Controls.Button])
        if (-not $btn -or -not $btn.DataContext) { return }
        $row = $btn.DataContext
        switch ($btn.Tag) {
            'install'   { Start-Install -Rows @($row) }
            'uninstall' { Start-Uninstall -Rows @($row) }
            'check'     { $script:NotifyDetect = $true; Start-Detect }
        }
    })

    $grid.AddHandler([System.Windows.Controls.CheckBox]::CheckedEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $cb = Find-AncestorControl -Source $e.OriginalSource -TargetType ([System.Windows.Controls.CheckBox])
        if ($cb -and $cb.DataContext) {
            $cb.DataContext.Selected = $true
            $script:SelectionState[(Get-RowKey $cb.DataContext)] = $true
        }
    })
    $grid.AddHandler([System.Windows.Controls.CheckBox]::UncheckedEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $cb = Find-AncestorControl -Source $e.OriginalSource -TargetType ([System.Windows.Controls.CheckBox])
        if ($cb -and $cb.DataContext) {
            $cb.DataContext.Selected = $false
            $script:SelectionState[(Get-RowKey $cb.DataContext)] = $false
        }
    })
}

# 各 List 模块：检测 / 修复按钮（把 ModuleId 存进 Tag，避免闭包陷阱）
foreach ($m in (Get-VCRedistModules)) {
    if ($m.Kind -ne 'List') { continue }
    $id = $m.Id
    $checkBtn  = Find-Element ("CheckBtn_" + $id)
    $repairBtn = Find-Element ("RepairBtn_" + $id)
    $checkBtn.Tag  = $id
    $repairBtn.Tag = $id
    $checkBtn.Add_Click({ param($sender, $e) Start-ListCheck -ModuleId ([string]$sender.Tag) })
    $repairBtn.Add_Click({ param($sender, $e) Start-ListRepair -ModuleId ([string]$sender.Tag) })
}

# ---------- 定时器：轮询后台进度并更新 UI ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $s = $script:sync
    if ($s.IsIndeterminate) {
        $script:ProgressBar.IsIndeterminate = $true
    } else {
        $script:ProgressBar.IsIndeterminate = $false
        $script:ProgressBar.Value = [double]$s.ProgressPercent
    }
    $script:StatusText.Text = [string]$s.StatusText

    if ($s.LogLines -and $s.LogLines -ne $script:LastLog) {
        $script:LogBox.Text = $s.LogLines
        $script:LogBox.ScrollToEnd()
        $script:LastLog = $s.LogLines
    }

    if ($script:LastBusy -and -not $s.Busy) {
        $script:LastBusy = $false
        $CancelBtn.IsEnabled = $false
        $op  = $s.Operation
        $err = $s.LastError
        $res = $s.Result

        if ($err) {
            $script:LogBox.Text = $s.LogLines
            $script:LogBox.ScrollToEnd()
            Write-VCRedistLog -Message ('操作失败：{0} —— {1}' -f $op, $err) -Level ERROR
            [System.Windows.MessageBox]::Show($err, '操作失败', 'OK', 'Error') | Out-Null
            Start-Operation -Operation 'detect' -Payload $null
        } else {
            Write-VCRedistLog -Message ('操作完成：{0}' -f $op) -Level INFO
            switch ($op) {
                'detect' {
                    Update-AllModuleDetection $res
                    $script:StatusText.Text = '检测完成'
                    if ($script:NotifyDetect) {
                        $script:NotifyDetect = $false
                        $issues = @()
                        foreach ($d in @($res)) {
                            if ($d.Kind -eq 'Table') {
                                $s2 = $d.Result.Summary
                                if ($s2.Damaged -gt 0)  { $issues += ('{0}：可能损坏 {1} 项' -f $d.Title, $s2.Damaged) }
                                if ($s2.Missing -gt 0)  { $issues += ('{0}：未安装 {1} 项' -f $d.Title, $s2.Missing) }
                                if ($s2.Residual -gt 0) { $issues += ('{0}：残留 {1} 项' -f $d.Title, $s2.Residual) }
                            } else {
                                $ls = $d.Result.Summary
                                if ($ls.StateKey -ne 'ok') { $issues += ('{0}：{1}' -f $d.Title, $ls.StateText) }
                            }
                        }
                        if ($issues.Count -eq 0) {
                            [System.Windows.MessageBox]::Show('✅ 检测完成：所有运行库状态正常，无需操作。', '检测成功', 'OK', 'Information') | Out-Null
                        } else {
                            [System.Windows.MessageBox]::Show(('检测完成，发现问题：' + "`r`n`r`n  · " + ($issues -join "`r`n  · ") + "`r`n`r`n" + '可在列表中查看详情，或点击「一键安装推荐项」修复。'), '检测完成（需处理）', 'OK', 'Warning') | Out-Null
                        }
                    }
                }
                'install' {
                    $script:LogBox.Text = $s.LogLines
                    $script:LogBox.ScrollToEnd()
                    $resArr = @($res | Where-Object { $_ })
                    $summary = ($resArr -join "`r`n")
                    $okCount   = @($resArr | Where-Object { $_ -like '✓*' }).Count
                    $failCount = @($resArr | Where-Object { $_ -like '✗*' }).Count
                    if ($failCount -eq 0 -and $okCount -gt 0) {
                        $title = '✅ 安装成功'; $icon = 'Information'
                        $msg = ('安装成功（{0} 项）：' -f $okCount) + "`r`n" + $summary
                    } elseif ($okCount -gt 0) {
                        $title = '⚠ 安装部分成功'; $icon = 'Warning'
                        $msg = ('安装部分成功（成功 {0} 项，失败 {1} 项）：' -f $okCount, $failCount) + "`r`n" + $summary
                    } else {
                        $title = '❌ 安装失败'; $icon = 'Error'
                        $msg = '安装失败：' + "`r`n" + $summary
                    }
                    [System.Windows.MessageBox]::Show($msg, $title, 'OK', $icon) | Out-Null
                    Start-Operation -Operation 'detect' -Payload $null
                }
                'uninstall' {
                    $script:LogBox.Text = $s.LogLines
                    $script:LogBox.ScrollToEnd()
                    $resArr = @($res | Where-Object { $_ })
                    $summary = ($resArr -join "`r`n")
                    $okCount   = @($resArr | Where-Object { $_ -like '✓*' }).Count
                    $failCount = @($resArr | Where-Object { $_ -like '✗*' }).Count
                    if ($failCount -eq 0 -and $okCount -gt 0) {
                        $title = '✅ 卸载成功'; $icon = 'Information'
                        $msg = ('卸载成功（{0} 项）：' -f $okCount) + "`r`n" + $summary
                    } elseif ($okCount -gt 0) {
                        $title = '⚠ 卸载部分成功'; $icon = 'Warning'
                        $msg = ('卸载部分成功（成功 {0} 项，失败 {1} 项）：' -f $okCount, $failCount) + "`r`n" + $summary
                    } else {
                        $title = '❌ 卸载失败'; $icon = 'Error'
                        $msg = '卸载失败：' + "`r`n" + $summary
                    }
                    [System.Windows.MessageBox]::Show($msg + "`r`n`r`n" + '正在重新检测以确认结果...', $title, 'OK', $icon) | Out-Null
                    Start-Operation -Operation 'detect' -Payload $null
                }
                'repair' {
                    $script:LogBox.Text = $s.LogLines
                    $script:LogBox.ScrollToEnd()
                    $resArr = @($res | Where-Object { $_ })
                    $summary = ($resArr -join "`r`n")
                    $okCount   = @($resArr | Where-Object { $_ -like '✓*' }).Count
                    $failCount = @($resArr | Where-Object { $_ -like '✗*' }).Count
                    if ($failCount -eq 0 -and $okCount -gt 0) {
                        [System.Windows.MessageBox]::Show($summary, '✅ 修复成功', 'OK', 'Information') | Out-Null
                    } else {
                        [System.Windows.MessageBox]::Show($summary, '❌ 修复失败', 'OK', 'Error') | Out-Null
                    }
                    Start-Operation -Operation 'detect' -Payload $null
                }
            }
        }
    }
    $script:LastBusy = $s.Busy
})
$timer.Start()

# ---------- 启动 ----------
$window.Add_Loaded({ Start-Detect })
$window.Add_Closed({
    Write-VCRedistLog -Message '==== 程序退出 ====' -Level INFO
    $timer.Stop()
    try { $script:WorkerRunspace.Dispose() } catch { }
})

$null = $window.ShowDialog()
