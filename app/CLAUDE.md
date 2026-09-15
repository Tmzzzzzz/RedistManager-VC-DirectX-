# CLAUDE.md —— 项目约定（供 Claude Code / 其他 agent 遵循）

本文件是 **运行库管理工具**（本目录 `app/`）的工作约定。修改任何代码前先读这里，避免破坏既有约定或与其他模块产生冲突。

## 项目一句话

Windows 桌面 GUI 工具，管理微软 VC 2005-2022 / DirectX 等运行库：**检测 / 诊断、下载 + 静默安装、静默卸载、修复、复制诊断报告**。

## 架构（模块化，切勿把新运行库写死进主程序）

- `VCRedistManager.ps1`：薄 GUI 壳，**模块无关**。页签 / 检测 / 安装 / 卸载 / 修复 / 报告全部由「模块注册表」驱动。
- `VCRedistManager.Core.psm1`：共享基础设施 + 模块自动发现（`Initialize-VCRedistModules`）+ 分发（`Get-AllModuleDetection` / `Invoke-ModuleOperation` / `Invoke-AllModuleActions`）。
- `Modules/*.psm1`：每个运行库模块一个文件，按下面「模块契约」实现。**加一个模块 = 加一个文件**，其余自动接上。
- `config.json`：顶层共享配置（`appName` / `appVersion` / `downloadDir` / `signatureSubject`）+ `modules.{id}`。

## 模块契约（必须遵守）

文件名 `Modules/<Id>.psm1`，`<Id>` 为 PascalCase（如 `Vc`、`DirectX`），小写后即模块 Id。只导出 4 个函数（`Export-ModuleMember` 只列这 4 个，其余内部函数保持私有）：

| 函数 | 参数 / 返回 |
|---|---|
| `Get-<Id>Manifest` | 无参 → `{ Title, Kind, Order }`，`Kind` ∈ `Table` / `List` |
| `Get-<Id>Detection` | 无参 → `{ Rows, Summary, Extra }` |
| `Invoke-<Id>Action` | `-Operation(install/uninstall/repair) -Rows -Sync` → 结果字符串数组 |
| `Get-<Id>Report` | `-Detection` → 字符串（报告片段，不含模块大标题） |

- **`Kind='Table'`**（逐行可操作：勾选 + 安装/卸载/检查）：
  - 行对象必须含：`Id、Arch、DisplayName、InternalVersion、StateKey、StateText、StateDetail、Necessity、NecessityLabel、NecessityReason、NecessityColor、Selected、Entries、Installer`。
  - `Summary`：`{ Total, Installed, Damaged, Missing, Residual }`；`Extra`：`{ ThirdParty = @(...) }`（无第三方则空数组）。
- **`Kind='List'`**（只读列表 + 检测/修复）：
  - 行对象必须含：`Name、Category、StateKey、StateText、Detail`。
  - `Summary`：`{ StateKey, StateText, StateDetail }`，`StateKey` ∈ `ok / partial / missing`。
  - 修复逻辑写在 `Invoke-<Id>Action -Operation 'repair'` 内。
- **共享能力**：模块内直接调用 Core 导出函数（`Get-ModuleConfig -Id <id>`、`Get-DllCheckResult`、`Start-VCRedistDownload`、`Test-VCRedistPackage`、`Invoke-ElevatedProcess`、`Test-ExitSuccess`、`Write-VCRedistLog`、`Format-Bytes`、`Get-DownloadDirectory`、`Test-Is64BitOS` 等）。**不要**访问 `$script:Config`（那是 Core 私有作用域；取本模块配置用 `Get-ModuleConfig -Id <id>`）。

## 硬性安全 / 编码约束（不可违反）

1. 只从 `microsoft.com` / `aka.ms` 官方源下载，**禁止第三方镜像**。
2. 下载后校验 Authenticode 数字签名（`Microsoft Corporation`）+ SHA256，任一不符即中止并报错。
3. 卸载、覆盖重装是破坏性操作，**必须二次确认**。
4. 不修改系统 PATH、不删除 WinSxS 共享组件、不自启、不留后台常驻进程。
5. **含中文的 `.ps1` / `.psm1` 必须保存为 UTF-8 with BOM**；`config.json` 必须 UTF-8 **无** BOM。（否则中文 Windows GBK 代码页下会乱码并导致语法错误。）

## 关键坑（容易踩，勿重犯）

- `Initialize-VCRedistModules` 内的 `Import-Module` **必须带 `-Global`**：该函数在 Core 的模块作用域内运行，不带 `-Global` 会把模块导入到 Core 自己的会话状态，主脚本按命名约定调用会「找不到命令」。
- 模块函数取配置一律用 `Get-ModuleConfig -Id <id>`，**不要**用 `$script:Config`。
- WPF 行内按钮路由事件里 `$e.Source` 可能是容器（DataGrid），**要用 `$e.OriginalSource` + `VisualTreeHelper` 向上回溯**定位真正按钮。
- 各 List 模块的「检测/修复」按钮回调通过 `.Tag` 传递 ModuleId（避免 PowerShell 闭包陷阱，勿改成直接捕获循环变量 `$id`）。

## 添加新模块步骤（清单）

1. 复制 `Modules/DirectX.psm1` → `Modules/<New>.psm1`，把文件名基名和 4 个导出函数的前缀全局改为 `<New>`。
2. 改 `Get-<New>Manifest` 的 `Title / Kind / Order`。
3. 实现 `Get-<New>Detection` / `Invoke-<New>Action` / `Get-<New>Report`。
4. （可选）在 `config.json` 的 `modules` 下加 `<new>`（小写）配置段。
5. 保存为 UTF-8 with BOM，运行 `Build-Exe.ps1` 重新打包。

**无需改动 `VCRedistManager.ps1` / `Core.psm1`。**

## 构建 / 校验命令

```powershell
# 重新生成 exe（自动 glob Modules/*.psm1 并嵌入）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Exe.ps1

# 语法校验（应为 0 errors）
[System.Management.Automation.Language.Parser]::ParseFile('.\VCRedistManager.ps1', [ref]$t, [ref]$e); $e.Count
```

交付物是单个 `VCRedistManager.exe`（双击运行，解压到 `%LOCALAPPDATA%\VCRedistManager\`）。
