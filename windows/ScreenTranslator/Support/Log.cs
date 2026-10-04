using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading;

namespace ScreenTranslator;

/// Thư mục dữ liệu: %APPDATA%\ScreenTranslator (tương đương ~/Library/Application Support/ScreenTranslator).
public static class AppPaths
{
    public static readonly string Root = Ensure(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenTranslator"));
    public static string Voices => Ensure(Path.Combine(Root, "voices"));
    public static string Shots => Ensure(Path.Combine(Root, "shots"));
    public static string File(string name) => Path.Combine(Root, name);
    public static string AppDir => AppContext.BaseDirectory;

    static string Ensure(string d) { Directory.CreateDirectory(d); return d; }
}

public static class Log
{
    public static readonly string FilePath = AppPaths.File("app.log");
    static readonly BlockingCollection<string> queue = new();
    static readonly Thread writer;

    static Log()
    {
        try
        {
            var fi = new FileInfo(FilePath);
            if (fi.Exists && fi.Length > 2_000_000) fi.Delete();
        }
        catch { }
        writer = new Thread(() =>
        {
            try
            {
                using var fs = new FileStream(FilePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                using var sw = new StreamWriter(fs, new UTF8Encoding(false)) { AutoFlush = true };
                foreach (var line in queue.GetConsumingEnumerable()) sw.Write(line);
            }
            catch { foreach (var _ in queue.GetConsumingEnumerable()) { } }
        }) { IsBackground = true, Name = "log.file" };
        writer.Start();
    }

    public static void Info(string msg) => Emit("INFO", msg);
    public static void Warn(string msg) => Emit("WARN", msg);
    public static void Error(string msg) => Emit("ERR ", msg);

    static void Emit(string level, string msg)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} {level} {msg}\n";
        try { Console.Error.Write(line); } catch { }
        System.Diagnostics.Debug.Write(line);
        queue.Add(line);
    }

    /// Chờ ghi hết log (dùng trước khi thoát ở chế độ CLI).
    public static void Flush()
    {
        for (int i = 0; i < 50 && queue.Count > 0; i++) Thread.Sleep(10);
    }
}
