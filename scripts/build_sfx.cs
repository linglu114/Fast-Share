using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;

class SfxLauncher
{
    [STAThread]
    static void Main()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "fastshare_" + Guid.NewGuid().ToString("N").Substring(0, 8));
        try
        {
            Directory.CreateDirectory(tempDir);
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("bundle"))
            using (var zip = new ZipArchive(stream, ZipArchiveMode.Read))
            {
                foreach (var entry in zip.Entries)
                {
                    var target = Path.Combine(tempDir, entry.FullName);
                    var targetDir = Path.GetDirectoryName(target);
                    if (!string.IsNullOrEmpty(targetDir)) Directory.CreateDirectory(targetDir);
                    using (var es = entry.Open())
                    using (var fs = File.Create(target))
                    {
                        es.CopyTo(fs);
                    }
                }
            }
            var exe = Path.Combine(tempDir, "fastshare.exe");
            if (!File.Exists(exe)) return;
            var proc = Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = tempDir, UseShellExecute = false });
            proc.WaitForExit();
        }
        finally
        {
            try { Directory.Delete(tempDir, true); } catch { }
        }
    }
}
