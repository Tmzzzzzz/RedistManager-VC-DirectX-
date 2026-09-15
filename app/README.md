# 运行库管理工具

一个用于管理微软 Visual C++（VC++）可再发行运行库（Redistributable）的 **Windows 桌面 GUI 工具**，覆盖 **VC 2005 ~ VC 2022** 全版本。核心能力：**检查 / 诊断**、**下载 / 静默安装**、**静默卸载**。

> 背景场景：Windows 电脑的 VC 运行库疑似异常（装过但文件可能损坏/缺失），且官方各版本安装包多、手动管理繁琐，本工具统一处理。

---

## 一、技术栈

- **PowerShell 5.1 + WPF (XAML)**：零依赖，Windows 自带，无需安装任何运行时 / SDK。
- **单文件 exe（C# 启动器）**：`RedistManager.exe` 内嵌全部 PowerShell 源码，双击即运行，无 cmd / 无控制台窗口。
- 直接调用注册表、MSI（`msiexec`）、Burn 引导包（Package Cache）、HTTP 下载。
- 安装 / 卸载通过 `Start-Process -Verb RunAs` 触发 UAC 提权（工具本身以普通权限运行，仅特权操作时提权）。

> 选型理由：运行库本身可能已损坏的极端场景下，PowerShell + WPF 仍然可用——它只依赖 Windows 自带的 .NET Framework 与 PowerShell（操作系统组件），不依赖任何 VC++ 运行库。

---

## 二、目录结构

```
app/
├── RedistManager.exe          # ★ 交付物：双击启动（自包含，无 cmd / 无控制台）
├── RedistManager.ps1          # 源码（主程序 WPF 入口，模块无关，嵌入 exe，UTF-8 BOM）
├── RedistManager.Core.psm1    # 源码（共享基础设施 + 模块注册表 / 分发，UTF-8 BOM）
├── Modules/                     # ★ 运行库模块（每个模块一个 .psm1，自动被发现）
│   ├── Vc.psm1                  #   VC 运行库模块（检测 / 安装 / 卸载 / 报告）
│   └── DirectX.psm1             #   DirectX 运行库模块（检测 / 修复 / 报告）
├── config.json                  # 源码（顶层共享配置 + modules.{id} 各模块配置，嵌入 exe）
├── Bootstrapper.cs              # 启动器源码（编译 exe 用，自动解压全部嵌入资源）
├── Build-Exe.ps1                # 重新构建 exe 的脚本（自动 glob Modules/*.psm1）
├── CLAUDE.md                    # 项目约定（模块契约 / 安全 / 编码约束，供 agent 遵循）
└── README.md
```

---

## 三、使用方法

### 启动

**双击 `RedistManager.exe`** 即可，无需 cmd、无控制台窗口、无第三方运行库依赖。

> 工作原理：exe 内嵌了全部 PowerShell 源码，首次运行时解压到 `%LOCALAPPDATA%\RedistManager\` 并在当前 STA 线程上托管运行。
> - 源码改动后，运行 `.\Build-Exe.ps1` 重新生成 exe。
> - 如需手动更新哈希 / 版本，编辑 `%LOCALAPPDATA%\RedistManager\config.json` 即可（exe 不会覆盖已存在的配置）。
> - 源码直接运行（开发调试）：`powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\RedistManager.ps1`

- 首次启动会自动进行「检查全部」，随后在界面右上角显示汇总。
- 界面采用分级页签，页签由**模块注册表**自动生成（不是写死），当前两个模块并列：
  - **「VC 运行库」页签**（`Kind=Table`）：主表每一行显示版本名称｜架构｜内部版本号｜状态（彩色）｜必要性｜操作按钮（安装 / 卸载 / 检查）。
  - **「DirectX 运行库」页签**（`Kind=List`）：细分列出每个 DirectX 组件（DLL）的归属 / 状态 / 版本，并提供「检测 / 修复」。

### 功能说明

| 功能 | 说明 |
|---|---|
| **检查全部** | 重新枚举各模块（注册表卸载项 + 关键 DLL / WinSxS），刷新全表状态与右上角汇总条（结果供「复制诊断报告」使用） |
| **一键安装推荐项** | 自动勾选并安装所有「必要」且未安装/损坏的项（VC 2015-2022、VC 2013 的 x86+x64） |
| **安装勾选项 / 行内「安装」** | 从微软官方源下载 → 校验签名/哈希 → 静默安装（UAC 提权）；已安装项可「覆盖重装」以修复损坏 |
| **卸载勾选项 / 行内「卸载」** | 二次确认后静默卸载（UAC 提权），多子版本一并列出 |
| **复制诊断报告** | 生成文本报告并复制到剪贴板 |
| **清理缓存** | 删除临时下载缓存（`%TEMP%\RedistManager`），释放磁盘空间 |
| **DirectX 检测 / 修复**（「DirectX 运行库」页签） | 逐项检测旧游戏 / 软件依赖的 DirectX 9/10/11 组件（`d3dx9_43.dll`、`d3dx10_43.dll`、`d3dx11_43.dll`、`d3dcompiler_43.dll`、`xinput1_3.dll`、`XAudio2_7.dll`），缺失时从官方源下载并静默安装（UAC 提权） |
| **打开日志** | 用记事本打开操作日志 `%LOCALAPPDATA%\RedistManager\logs\RedistManager.log` |

### 操作反馈与日志

- 所有按钮点击后均有明确反馈弹窗，区分 **成功 / 失败 / 无需操作**：
  - **检查全部** → 无问题时提示「所有运行库状态正常，无需操作」；有问题时逐模块列出「可能损坏 / 未安装 / 残留 / 组件缺失」的项数。
  - **安装 / 卸载** → 逐项显示 ✓ / ✗，并按「成功 / 部分成功 / 失败」给出标题与图标。
  - **DirectX 检测 / 修复** → 区分「已就绪，无需修复」/「修复成功」/「修复失败」。
- 全程操作自动写入日志文件（UTF-8）：启动、开始操作、逐项结果（安装 / 卸载 / DirectX）、完成 / 失败、清理缓存、退出，均带时间戳与级别（INFO / WARN / ERROR）。

---

## 四、检测 / 状态判定

每个「版本 + 架构」组合判定为四种状态：

| 状态 | 判定依据 |
|---|---|
| **已安装** | 注册表有卸载项，且关键 DLL 存在（多子版本时显示「已安装（多版本）」） |
| **可能损坏 / 不完整** | 注册表有卸载项，但关键 DLL 缺失 / 异常 |
| **未安装** | 注册表无卸载项，且对应 DLL 不存在 |
| **残留** | 注册表无卸载项，但 DLL / WinSxS 组件仍存在 |

关键事实（已内建，无需调整）：

- **VC 2015 / 2017 / 2019 / 2022 是同一个可再发行包**（内部版本号均为 14.x），合并为一个条目「VC 2015-2022」。
- **x86 与 x64 是并列关系**：64 位系统上大量 32 位程序仍需 x86 运行库，两者都要装。
- **架构判定解析 DisplayName 中的 "x64"/"x86"**，不依据注册表视图（VC 2012/2013/2015-2022 的 x64 包由 32 位 Burn 引导程序安装，卸载项落在 WOW6432Node）。
- **2005 / 2008 以注册表卸载项为主判据**，其 DLL 走 WinSxS 并排程序集机制；「WinSxS 有、注册表无」判定为「残留」而非「已安装」。
- **第三方捆绑运行库**（如 "NI Microsoft Visual C++ 2015 Run-Time"）单独分组展示，**不纳入安装 / 卸载目标**。

---

## 五、下载源与校验（config.json）

所有下载地址集中在 `config.json`，**只使用 `microsoft.com` / `aka.ms` 官方源**，禁止第三方镜像。

每个安装包执行 **双重校验**：

1. **Authenticode 数字签名**：必须为 `Valid` 且签发者为 `Microsoft Corporation`（强制）。
2. **SHA256 哈希**：与 `config.json` 中配置的 `sha256` 对照（当该字段为空时，仅做签名校验，并在日志中记录）。

> ✅ 关于 SHA256：`config.json` 已写入全部 12 个 VC 安装包 + 1 个 DirectX 安装包（`directx_Jun2010_redist.exe`）的**实测 SHA256**（2026-09-15 下载实测，且每个包的 Authenticode 签名均校验为 Microsoft Corporation）。官方安装包会随版本更新，建议定期重新核实；若某包更新导致哈希不匹配，用下方命令重新实测并更新：

```powershell
Get-FileHash .\vc_redist.x64.exe -Algorithm SHA256
```

把结果填入对应 `installers.x86/x64.sha256` 即可。签名校验已足够识别「被篡改 / 来源非官方」的文件；哈希用于进一步固定版本。

### 模块配置结构（`config.json`）

`config.json` 顶层只保留**共享配置**（`appName` / `appVersion` / `downloadDir` / `signatureSubject`），各运行库的具体配置统一收进 `modules.{id}`：

- `modules.vc`：`necessityRules`（必要 / 可选 / 不推荐的颜色、理由、默认勾选）+ `versions`（6 个版本的检测依据与安装包）。
- `modules.directx`：
  - `dlls`：检测的关键 DLL（`d3dx9_43.dll`、`d3dx10_43.dll`、`d3dx11_43.dll`、`d3dcompiler_43.dll`、`xinput1_3.dll`、`XAudio2_7.dll`，位于 `System32`）。
  - `installer`：`directx_Jun2010_redist.exe`（官方完整再发行包，约 96 MB）+ 实测 SHA256。

DirectX 安装流程：下载 → 校验签名/哈希 → 以 `/Q /T:目录` 静默解压 → 执行解压出的 `DXSETUP.exe /silent` 完成安装（两步均需 UAC 提权）。

> 旧版本工具升级后，本地已解压的 `config.json` 若仍是顶层 `versions` / `directx` 旧结构（无 `modules` 段），程序启动时会自动迁移为 `modules.*`，无需重新构建。

---

## 六、卸载机制（实测确认）

- **Burn 引导包**（VC 2010/2012/2013/2015-2022）：执行 Package Cache 中的 `<GUID>\*.exe /uninstall /quiet /norestart`，执行前 `Test-Path` 校验缓存是否仍在；缺失则提示重下官方包。
- **纯 MSI**（VC 2005/2008，及部分 2010）：`MsiExec.exe /X{ProductCode} /qn /norestart`；失败时返回退出码（如 1612 = 找不到安装源，处置见「常见问题」）。

---

## 七、诊断报告格式

「复制诊断报告」遍历模块注册表、拼接各模块报告片段，生成的文本结构如下：

```
============================================
  运行库管理工具 · 诊断报告
============================================
生成时间：2026-09-15 12:00:00
系统架构：x64

【VC 运行库】
  【总体情况】
    已安装：8 / 12
    可能损坏：1
    未安装：3
    残留：0

  【明细】
    [已安装] VC 2015-2022 x64（内部 14.x）—— 14.38.33130
    [可能损坏] VC 2013 x86（内部 12.0）—— 关键 DLL 缺失：msvcp120.dll
    ...

  【第三方捆绑运行库】（不纳入安装 / 卸载目标）
    - NI Microsoft Visual C++ 2015 Run-Time（12.0.40660）

  【建议操作】
    - 覆盖重装修复损坏：VC 2013 x86
    - 安装：VC 2010 x64（可选）

【DirectX 运行库】
  部分缺失：缺失：d3dx9_43.dll, xinput1_3.dll
  组件明细：
    [缺失] d3dx9_43.dll（DirectX 9）
    ...
```

---

## 八、安全边界

1. 只从 `microsoft.com` / `aka.ms` 官方源下载，禁止第三方镜像。
2. 下载后校验 Authenticode 签名 + SHA256，不符即中止并报错。
3. 卸载、覆盖重装为破坏性操作，均二次确认。
4. 不修改系统 PATH、不删除 WinSxS 共享组件、不做清单之外的系统改动。
5. 工具不自启、不留后台常驻进程。

---

## 九、编码要求（重要）

含中文的 `.ps1` / `.psm1` 必须保存为 **UTF-8 with BOM**。否则在中文 Windows（GBK 代码页）下会被按 ANSI 解析，中文乱码并直接导致语法错误。

当前仓库中的 `RedistManager.ps1`、`RedistManager.Core.psm1` 及 `Modules\*.psm1` 均已带 BOM。若自行编辑后出现乱码，请用以下方式重新保存为 UTF-8 BOM：

```powershell
$enc = New-Object System.Text.UTF8Encoding($true)
$c = [System.IO.File]::ReadAllText('.\RedistManager.ps1')
[System.IO.File]::WriteAllText('.\RedistManager.ps1', $c, $enc)
```

---

## 十、打包 / 分发

- **交付（推荐）：** 复制 `RedistManager.exe` 单个文件到目标机，双击即可。零依赖，目标机仅需 Windows 10/11（自带 .NET Framework 4.x + PowerShell 5.1）。
- **重新构建：** 修改源码后，在 PowerShell 中运行 `.\Build-Exe.ps1`（使用本机 .NET Framework 自带的 `csc.exe` 编译，将 `.ps1`/`.psm1`/`config.json` 重新嵌入）。
- **自定义图标 / 版本信息：** 编辑 `Bootstrapper.cs` 顶部的 `AssemblyTitle` 等特性后重新构建。

---

## 十一、如何添加新模块（扩展指南）

要新增一个运行库管理模块（如 .NET Framework、WebView2、Java 等），**只需在 `Modules\` 下加一个 `.psm1` 文件**，其余（页签、检测、安装/卸载/修复、诊断报告、exe 打包）自动接上。

### 模块契约

1. **文件名**：`Modules/<Id>.psm1`，`<Id>` 为 PascalCase（如 `Vc`、`DirectX`），小写后即模块 Id（用于控件命名、配置段 key、分发）。
2. **导出 4 个函数**（`Export-ModuleMember` 只列这 4 个；其余内部函数保持私有）：

| 函数 | 职责 | 参数 / 返回 |
|---|---|---|
| `Get-<Id>Manifest` | 自描述 | 无参；返回 `{ Title, Kind, Order }`，`Kind` ∈ `Table` / `List` |
| `Get-<Id>Detection` | 检测 | 无参；返回 `{ Rows, Summary, Extra }` |
| `Invoke-<Id>Action` | 后台执行 | `-Operation(install/uninstall/repair) -Rows -Sync`；返回结果字符串数组 |
| `Get-<Id>Report` | 报告片段 | `-Detection`；返回字符串 |

3. **`Kind='Table'`**（逐行可操作：勾选 + 安装/卸载/检查）：
   - 行对象必须含：`Id、Arch、DisplayName、InternalVersion、StateKey、StateText、StateDetail、Necessity、NecessityLabel、NecessityReason、NecessityColor、Selected、Entries、Installer`。
   - `Summary`：`{ Total, Installed, Damaged, Missing, Residual }`；`Extra`：`{ ThirdParty = @(...) }`（无第三方则空数组）。
4. **`Kind='List'`**（只读列表 + 检测/修复）：
   - 行对象必须含：`Name、Category、StateKey、StateText、Detail`。
   - `Summary`：`{ StateKey, StateText, StateDetail }`，`StateKey` ∈ `ok / partial / missing`。
   - 在 `Invoke-<Id>Action -Operation 'repair'` 中实现修复。
5. **共享能力**：模块内可直接调用 Core 导出的函数（`Get-ModuleConfig -Id`、`Get-DllCheckResult`、`Start-RedistDownload`、`Test-RedistPackage`、`Invoke-ElevatedProcess`、`Test-ExitSuccess`、`Write-RedistLog`、`Format-Bytes`、`Get-DownloadDirectory` 等）。**不要**访问 `$script:Config`（那是 Core 自己的作用域，请用 `Get-ModuleConfig -Id <id>` 取本模块配置）。

### 添加步骤清单

1. 复制 `Modules\DirectX.psm1`（或 `Vc.psm1`）为 `Modules\<New>.psm1`；
2. 把文件名基名和 4 个导出函数的前缀全局改为 `<New>`；
3. 改 `Get-<New>Manifest` 的 `Title / Kind / Order`；
4. 实现 `Get-<New>Detection` / `Invoke-<New>Action` / `Get-<New>Report`；
5. （可选）在 `config.json` 的 `modules` 下加 `<new>`（小写）配置段；
6. 保存为 **UTF-8 with BOM**，运行 `Build-Exe.ps1` 重新打包。

无需改动 `RedistManager.ps1` / `Core.psm1`——它们会自动发现、注册并按 `Order` 排序生成页签与分发操作。

---

## 十二、常见问题

- **行内「安装 / 卸载 / 检查」按钮已修复**：现通过可视化树正确定位被点击的按钮，点击后立即弹出确认框 / 反馈。若仍无反应，请确认当前账户允许 UAC 提权，且能访问 `microsoft.com`。
- **「可能损坏」如何修复？** 对该行点「安装」执行覆盖重装即可。
- **卸载失败错误 1612？** 说明 MSI 安装源已丢失，按界面提示重新下载对应官方安装包重建缓存后再卸载。
- **第三方捆绑项为何不能卸载？** 这些由其他软件（如 NI LabVIEW）自带，卸载会破坏依赖它的软件，故仅展示。
