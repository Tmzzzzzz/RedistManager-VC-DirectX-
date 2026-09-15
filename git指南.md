# Git 发布指南 —— 把「运行库管理工具」推到 GitHub

本指南带你**从零**把这个项目上传到 GitHub。按顺序执行即可，每步都有可直接复制的命令。

> 环境说明：以下命令在 **Git Bash**（Windows 自带安装 Git 后附带的终端）或本仓库的 bash 环境里均可运行。若你在 PowerShell 里运行，命令同样适用。

---

## 0. 开始前，先了解两个决定

1. **要不要提交 exe？**
   已默认**不提交** `app/VCRedistManager.exe`（见 `.gitignore`）。它是构建产物，正确做法是用 GitHub Releases 发布（见第 7 步）。如果你坚持直接放进仓库，删除 `.gitignore` 中对应那一行即可。
2. **仓库名建议用英文**：GitHub 仓库名建议用 `VCRedistManager`（避免中文/空格带来的链接问题），本地文件夹名无需改动。

---

## 1. 安装 Git（如已安装可跳过）

命令行检查：

```bash
git --version
```

能输出版本号（如 `git version 2.x`）即已安装。否则到 <https://git-scm.com/download/win> 下载安装。

---

## 2. 配置身份（仅首次需要）

```bash
git config --global user.name  "你的名字"
git config --global user.email "你的邮箱@example.com"

# Windows 换行符默认策略（保持默认即可，源码 CRLF 不会被破坏）
git config --global core.autocrlf true
```

---

## 3. 确认待提交内容

`app/` 之外我已经帮你准备了：`.gitignore`、`README.md`、`git指南.md`。执行以下命令确认哪些文件会被跟踪、哪些被忽略：

```bash
cd "C:/Users/11576/Desktop/VC运行库下载工具"
git status
```

> 注意：`.claude/` 和 `app/VCRedistManager.exe` 应显示为「被忽略」，不会进入提交。

---

## 4. 初始化仓库并首次提交

```bash
cd "C:/Users/11576/Desktop/VC运行库下载工具"

git init
git add .
git commit -m "初始提交：运行库管理工具（VC 2005-2022 / DirectX）"
```

---

## 5. 在 GitHub 上创建空仓库

1. 登录 <https://github.com> → 右上角 `+` → **New repository**。
2. 仓库名填 `VCRedistManager`，可加一句描述。
3. 选 **Public** 或 **Private**。
4. ⚠️ **不要**勾选 "Add a README / .gitignore / license"（保持空仓库，否则和本地仓库冲突）。
5. 点 **Create repository**。

创建后，页面会显示一段快速命令，里面包含你的仓库地址（形如 `https://github.com/你的用户名/VCRedistManager.git`）。

---

## 6. 关联远程并推送

把下面地址换成你自己的：

```bash
cd "C:/Users/11576/Desktop/VC运行库下载工具"

git remote add origin https://github.com/你的用户名/VCRedistManager.git
git branch -M main
git push -u origin main
```

首次推送会弹窗要求登录 GitHub（浏览器授权即可）。

> 备选（已安装 `gh` CLI 时更省事）：
> ```bash
> gh auth login
> gh repo create VCRedistManager --public --source . --push
> ```

推送成功后，刷新 GitHub 页面即可看到全部源码与两份文档。

---

## 7.（可选）用 Releases 发布 exe

按推荐做法，exe 不入库，而是作为 Release 资产发布：

1. 本地构建 exe：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\app\Build-Exe.ps1
   ```
2. GitHub 仓库页 → **Releases** → **Create a new release**。
3. 填版本号（如 `v1.1.0`），把 `app\VCRedistManager.exe` 拖进附件区。
4. 发布后，别人就能在 README 的「快速开始」里直接下载 exe。

---

## 8.（可选）补充 LICENSE

公开仓库若无许可证，他人默认**无权复用**你的代码。建议加一个：

- 直接在你的 GitHub 仓库首页点 **Add file → Create new file → 文件名 `LICENSE`**，选一个模板（个人/开源常用 [MIT](https://choosealicense.com/licenses/mit/)）。
- 本地也可创建后提交：
  ```bash
  # 例如 MIT 许可证，把全文写入 LICENSE 后：
  git add LICENSE
  git commit -m "添加 MIT 许可证"
  git push
  ```

---

## 9. 日常更新（以后每次改动后）

```bash
cd "C:/Users/11576/Desktop/VC运行库下载工具"

git add .
git commit -m "描述这次改了什么"
git push
```

---

## 常见问题

| 现象 | 解决 |
|---|---|
| `git push` 提示认证失败 | 用浏览器登录一次 GitHub，或改用 `gh auth login` 后再推 |
| 中文文件名显示乱码 | 终端编码问题，不影响提交；GitHub 页面显示正常 |
| 提示 `src refspec main does not match any` | 先完成第 4 步的 `git commit` 再推 |
| 想撤回某次提交（未 push 时） | `git reset --soft HEAD~1`（保留改动） |
| 源码在别的电脑/系统上中文乱码 | 源文件已存为 UTF-8 BOM；确保别人拉取后不另存为 ANSI 即可 |
