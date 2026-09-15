# Build-Exe.ps1
# Compiles RedistManager.exe (self-contained host) from Bootstrapper.cs.
# Layout: this script and Bootstrapper.cs live in build/; runtime sources in src/;
# icon in assets/. Output is written to app/RedistManager.exe (repo-root deliverable).
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$root = Split-Path $PSScriptRoot -Parent     # .../app
$srcDir = Join-Path $root 'src'
$assetsDir = Join-Path $root 'assets'

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw 'csc.exe not found (requires .NET Framework 4.x)' }

$automation = (Get-ChildItem 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\*\System.Management.Automation.dll' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $automation) { throw 'System.Management.Automation.dll not found in GAC' }

$winforms = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Windows.Forms.dll'

$out = Join-Path $root 'RedistManager.exe'
$src = Join-Path $PSScriptRoot 'Bootstrapper.cs'
$icon = Join-Path $assetsDir 'app.ico'

$moduleFiles = Get-ChildItem (Join-Path $srcDir 'Modules') -Filter '*.psm1' -File -ErrorAction SilentlyContinue | Sort-Object Name

$resources = @(
    "/resource:$($srcDir)\RedistManager.Core.psm1,RedistManager.Core.psm1",
    "/resource:$($srcDir)\RedistManager.ps1,RedistManager.ps1",
    "/resource:$($srcDir)\config.json,config.json"
)
foreach ($f in $moduleFiles) {
    # Modules use "Modules.<name>" as the resource id (Bootstrapper extracts to Modules\ subdir).
    $resources += ("/resource:{0},Modules.{1}" -f $f.FullName, $f.Name)
}

$cscArgs = @(
    '/nologo', '/target:winexe', '/codepage:65001', '/optimize+',
    "/out:$out",
    "/r:$automation",
    "/r:$winforms"
)
if (Test-Path -LiteralPath $icon) {
    $cscArgs += "/win32icon:$icon"
}
$cscArgs += $resources + @($src)

& $csc $cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

Write-Host "Built: $out"
Write-Host ('Size: {0:N0} bytes' -f (Get-Item -LiteralPath $out).Length)
