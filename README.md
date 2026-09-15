# 运行库管理工具 · RedistManager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)

如果你也遇到程序发生了 "0xc000007b" 报错，怀疑 **VC 运行库 / DirectX 出了问题**，但又嫌一个个重装太过麻烦，**不妨来试试这个运行库管理工具？**

一个用于管理微软 **Visual C++ 2005–2022** 与 **DirectX 9/10/11 旧组件** 运行库的 **Windows 桌面 GUI 工具**，覆盖 **检查 / 诊断、下载 + 静默安装、静默卸载、修复、复制诊断报告** 全流程。

> 零依赖：仅用 Windows 自带的 **PowerShell 5.1 + WPF（.NET Framework）**，无需安装任何第三方运行时 / SDK。单文件 exe 双击即用，无控制台窗口。

---

## ✨ 功能特性

- **检查 / 诊断**：不只看「是否在已安装列表」，还能识别「装了但 DLL 缺失/损坏」「残留」等异常状态。
- **一键安装推荐项**：自动勾选并安装所有「必要」且缺失/损坏的运行库。
- **下载 + 静默安装**：从微软官方源下载 → 校验数字签名 + SHA256 → 静默安装（UAC 提权）。
- **静默卸载 / 覆盖重装**：二次确认后卸载；对「可能损坏」项可覆盖重装修复。
- **DirectX 修复**：逐项检测并补齐旧游戏依赖的 DX9/10/11 组件（`d3dx9_43.dll` 等 6 项）。
- **必要性分级**：每个运行库标注「必要 / 可选 / 不推荐」，帮助判断该装哪些。
- **全程日志**：所有操作写入 `%LOCALAPPDATA%\RedistManager\logs\`。

覆盖版本：VC 2005 / 2008 / 2010 / 2012 / 2013 / 2015-2022（含 x86 + x64）＋ DirectX 旧组件。

---

## 📦 快速开始

### 方式一：直接运行（推荐）

1. 到本仓库 **Releases** 页面下载 `RedistManager.exe`（单个文件）。
2. 双击运行即可，**无需安装**，也无需任何前置环境（Windows 10/11 自带所需组件）。

> 若 Releases 中暂无构建产物，请参考「方式二」自行编译。

### 方式二：从源码构建

```powershell
# 在 app 目录下，使用系统自带 csc.exe 重新编译单文件 exe
powershell -NoProfile -ExecutionPolicy Bypass -File .\app\Build-Exe.ps1
```

构建产物为 `app\RedistManager.exe`。

### 方式三：源码直接运行（开发调试）

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\app\RedistManager.ps1
```

---

## 📁 目录结构

```
.
├── LICENSE                      # MIT 开源许可证
├── README.md                    # 本文件（仓库首页 / 快速上手）
└── app/                         # 程序本体
    ├── RedistManager.exe        # 交付物：单文件 exe（由 Build-Exe.ps1 生成，不入库）
    ├── RedistManager.ps1        # 主程序（WPF 入口，模块无关）
    ├── RedistManager.Core.psm1  # 共享基础设施（配置/下载/校验/提权/模块分发）
    ├── Modules/                 # 运行库模块（自动发现，加一个模块=加一个文件）
    │   ├── Vc.psm1              # VC 运行库模块
    │   └── DirectX.psm1         # DirectX 运行库模块
    ├── config.json              # 顶层共享配置 + 各模块配置（下载源/哈希/必要性规则）
    ├── Bootstrapper.cs          # C# 启动器源码
    ├── Build-Exe.ps1            # 重新构建 exe 的脚本
    ├── README.md                # 详细文档（功能/检测/卸载机制/扩展指南/FAQ）
    └── CLAUDE.md                # 项目约定（模块契约/安全/编码约束）
```

---

## 🔒 安全设计

- 只从 `microsoft.com` / `aka.ms` 官方源下载，禁止第三方镜像。
- 下载后强制校验 Authenticode 数字签名（`Microsoft Corporation`）＋ SHA256，不符即中止。
- 卸载、覆盖重装为破坏性操作，均二次确认。
- 不修改系统 PATH、不删除 WinSxS 共享组件、不自启、不留后台常驻进程。

---

## 📖 详细文档

功能说明、检测/状态判定逻辑、卸载机制、如何添加新模块、常见问题等，见 **[app/README.md](app/README.md)**。

---

## 🛠️ 技术栈

- PowerShell 5.1 + WPF（XAML）
- C# 启动器（内嵌全部源码，编译为单文件 exe）
- 直接调用注册表、MSI（`msiexec`）、Burn 引导包（Package Cache）、HTTP 下载

---

## 🤝 参与贡献

欢迎任何形式的贡献，包括但不限于：

- **提 Issue**：报告 bug、反馈使用问题，或提议新功能 / 新的运行库支持。
- **提 PR**：新增运行库模块（在 `Modules/` 下加一个 `.psm1` 即可，见 [如何添加新模块](app/README.md#十一如何添加新模块扩展指南)）、修复问题、改进文档。
- **维护下载源**：官方安装包会随版本更新，SHA256 需定期核对（见 [下载源与校验](app/README.md#五下载源与校验configjson)）。

动手前请先阅读 [app/CLAUDE.md](app/CLAUDE.md) 中的模块契约与安全 / 编码约束（含中文的 `.ps1` / `.psm1` 必须保存为 UTF-8 with BOM）。

如果这个项目对你有帮助，欢迎点个 ⭐ Star！

---

## ⚠️ 免责声明

- 本工具**不隶属于微软**，仅从微软官方源（`microsoft.com` / `aka.ms`）下载并安装微软发布的运行库组件。
- 各运行库组件（Visual C++ Redistributable、DirectX 等）的版权归 **Microsoft Corporation** 所有。
- 安装 / 卸载会改动系统状态，请自行评估风险；本项目不提供任何担保（见许可证）。

---

## 📄 许可证

本项目采用 [MIT License](LICENSE)。

- **允许**：自由使用、复制、修改、合并、发布、分发、再授权、销售（含商用、闭源）。
- **要求**：在所有副本或重要部分中保留版权声明与许可声明。
- **不担保**：软件按「现状」提供，无任何明示或暗示的保证；作者不承担因使用本软件造成的任何损失。

Copyright © 2026 Tmzzzzzz
