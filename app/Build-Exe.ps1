# Build-Exe.ps1
# Compiles RedistManager.exe (self-contained host) from Bootstrapper.cs.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Exe.ps1

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw 'csc.exe not found (requires .NET Framework 4.x)' }

$automation = (Get-ChildItem 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\*\System.Management.Automation.dll' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $automation) { throw 'System.Management.Automation.dll not found in GAC' }

$winforms = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll'

$out = Join-Path $PSScriptRoot 'RedistManager.exe'
$src = Join-Path $PSScriptRoot 'Bootstrapper.cs'

$moduleFiles = Get-ChildItem (Join-Path $PSScriptRoot 'Modules') -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Sort-Object Name

$resources = @(
    "/resource:$($PSScriptRoot)\RedistManager.Core.psm1,RedistManager.Core.psm1",
    "/resource:$($PSScriptRoot)\RedistManager.ps1,RedistManager.ps1",
    "/resource:$($PSScriptRoot)\config.json,config.json"
)
foreach ($f in $moduleFiles) {
    # 模块以 "Modules.<文件名>" 作为资源标识（Bootstrapper 据此解压到 Modules\ 子目录）
    $resources += ("/resource:{0},Modules.{1}" -f $f.FullName, $f.Name)
}

$cscArgs = @(
    '/nologo', '/target:winexe', '/codepage:65001', '/optimize+',
    "/out:$out",
    "/r:$automation",
    "/r:$winforms"
) + $resources + @($src)

& $csc $cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

Write-Host "Built: $out"
Write-Host ('Size: {0:N0} bytes' -f (Get-Item -LiteralPath $out).Length)
