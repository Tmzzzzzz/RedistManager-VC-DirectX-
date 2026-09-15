// ============================================================
//  Bootstrapper.cs —— 运行库管理工具 启动器（编译为单文件 exe）
//
//  作用：把嵌入的 PowerShell 源码（.ps1/.psm1/config.json）解压到
//        %LOCALAPPDATA%\VCRedistManager，并在当前 STA 线程上托管
//        PowerShell 运行 WPF 界面。无需 cmd、无控制台窗口。
//
//  编译：见 Build-Exe.ps1（csc.exe /target:winexe）
// ============================================================

using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("运行库管理工具")]
[assembly: AssemblyProduct("运行库管理工具")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace VCRedistManager
{
    internal static class Program
    {
        private static readonly string WorkDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VCRedistManager");

        private static Mutex _mutex;

        [STAThread]
        private static int Main()
        {
            // 单实例：避免并发解压/多开
            bool createdNew;
            _mutex = new Mutex(true, "VCRedistManager.SingleInstance", out createdNew);
            if (!createdNew)
            {
                MessageBox.Show(
                    "运行库管理工具已在运行。",
                    "运行库管理工具",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return 0;
            }

            try
            {
                ExtractResources();
                RunScript();
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "启动失败：" + ex.Message,
                    "运行库管理工具",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                try { _mutex.ReleaseMutex(); } catch { }
            }
        }

        private static void ExtractResources()
        {
            Directory.CreateDirectory(WorkDir);
            Directory.CreateDirectory(Path.Combine(WorkDir, "Modules"));

            // 自动解压全部嵌入资源（脚本 / 核心 / 各模块 / 配置）
            foreach (string name in Assembly.GetExecutingAssembly().GetManifestResourceNames())
            {
                // 配置仅首次释放，之后用户可自行修改并保留；其余始终与 exe 版本同步覆盖
                bool overwrite = (name != "config.json");
                Extract(name, overwrite);
            }
        }

        private static void Extract(string name, bool overwrite)
        {
            // 模块以 "Modules.<文件名>" 作为资源标识，映射到 Modules\ 子目录
            string relPath = name.StartsWith("Modules.", StringComparison.Ordinal)
                ? Path.Combine("Modules", name.Substring("Modules.".Length))
                : name;

            string dest = Path.Combine(WorkDir, relPath);
            if (!overwrite && File.Exists(dest)) return;

            using (Stream src = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (src == null)
                    throw new FileNotFoundException("缺少嵌入资源：" + name);

                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                using (FileStream dst = File.Create(dest))
                {
                    src.CopyTo(dst);
                }
            }
        }

        private static void RunScript()
        {
            string mainPath = Path.Combine(WorkDir, "VCRedistManager.ps1");

            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                // 强制 STA：WPF 界面必须在 STA 线程上运行
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.ApartmentState = ApartmentState.STA;
                rs.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;

                    // 以 & 调用脚本文件，保证脚本内 $PSCommandPath / $MyInvocation 指向真实文件
                    ps.AddScript("& '" + mainPath.Replace("'", "''") + "'").Invoke();

                    if (ps.HadErrors)
                    {
                        StringBuilder sb = new StringBuilder();
                        foreach (ErrorRecord e in ps.Streams.Error)
                            sb.AppendLine(e.ToString());
                        throw new InvalidOperationException(sb.ToString());
                    }
                }
            }
        }
    }
}
