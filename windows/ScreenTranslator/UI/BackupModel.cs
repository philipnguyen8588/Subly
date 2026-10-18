using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace ScreenTranslator;

/// Trạng thái sao lưu / khôi phục dùng chung cho Cài đặt → Sao lưu và các cờ test. Dùng trên UI thread.
public static class BackupModel
{
    public static List<BackupInfo> backups { get; private set; } = new();
    public static string? busy { get; private set; }          // đang làm gì
    public static double? progress { get; private set; }      // 0…1 khi đang tải lên / tải về
    public static string? message { get; private set; }
    public static bool isError { get; private set; }
    public static bool loaded { get; private set; }

    /// Có gì đổi → vẽ lại trang (luôn bắn trên UI thread).
    public static event Action? Changed;
    static void Notify() => App.RunOnUI(() => Changed?.Invoke());

    public static bool LoggedIn => BackupClient.Token.Length > 0 && AppSettings.shared.accountUser.Length > 0;
    public static string ThisMachine => BackupClient.MachineID;

    static void Report(string text, bool error)
    {
        message = text; isError = error;
        if (error) Log.Warn($"Sao lưu: {text}"); else Log.Info($"Sao lưu: {text}");
        Notify();
    }

    static void Fail(Exception e)
    {
        if (e is BackupClient.BackupException { unauthorized: true }) SecretStore.Set("", BackupClient.TokenName);
        Report(e.Message, true);
    }

    static void SetProgress(double p) => App.RunOnUI(() => { progress = p; Changed?.Invoke(); });

    public static async Task<bool> Login(string username, string password)
    {
        busy = "Đang đăng nhập…"; Notify();
        try
        {
            AppSettings.shared.accountUser = await BackupClient.Login(username, password);
            Report($"Đã đăng nhập {AppSettings.shared.accountUser}", false);
            busy = null;
            await Refresh();
            return true;
        }
        catch (Exception e) { Fail(e); return false; }
        finally { busy = null; Notify(); }
    }

    public static async Task Logout()
    {
        await BackupClient.Logout();
        AppSettings.shared.accountUser = "";
        backups = new(); loaded = false; message = null;
        Notify();
    }

    public static async Task Refresh()
    {
        if (!LoggedIn) return;
        try { backups = await BackupClient.List(); loaded = true; Notify(); }
        catch (Exception e) { Fail(e); }
    }

    /// Sao lưu dữ liệu máy này lên server (ghi đè bản cũ của máy này).
    public static async Task<bool> BackupNow()
    {
        if (busy != null) return false;
        busy = "Đang đóng gói dữ liệu…"; progress = null; Notify();
        string? zip = null;
        try
        {
            zip = await BackupArchive.Export();
            var size = new FileInfo(zip).Length;
            busy = $"Đang tải lên {Size(size)}…"; progress = 0; Notify();
            var info = await BackupClient.Upload(zip, SetProgress);
            Report($"Đã sao lưu {Size(info.size)} lúc {info.Date:HH:mm}", false);
            busy = null;
            await Refresh();
            return true;
        }
        catch (Exception e) { Fail(e); return false; }
        finally
        {
            if (zip != null) try { Directory.Delete(Path.GetDirectoryName(zip)!, true); } catch { }
            busy = null; progress = null; Notify();
        }
    }

    /// Tải bản của một máy về, giải nén chờ sẵn rồi khởi động lại app để thay dữ liệu.
    public static async Task Restore(BackupInfo b, string[] args)
    {
        if (busy != null) return;
        busy = $"Đang tải bản sao lưu {Size(b.size)}…"; progress = 0; Notify();
        var zip = AppPaths.File("restore-download.zip");
        try
        {
            await BackupClient.Download(b.machine, zip, SetProgress);
            busy = "Đang giải nén…"; progress = null; Notify();
            var m = await Task.Run(() => BackupArchive.Stage(zip));
            try { File.Delete(zip); } catch { }
            Log.Info($"Sao lưu: đã chuẩn bị bản của {m.machineName} ({m.profiles} game, {m.historyRows} dòng) → khởi động lại");
            Pipeline.shared.Stop();
            BackupArchive.Relaunch(args);
        }
        catch (Exception e) { Fail(e); }
        finally
        {
            try { if (File.Exists(zip)) File.Delete(zip); } catch { }
            busy = null; progress = null; Notify();
        }
    }

    public static async Task Delete(BackupInfo b)
    {
        try { await BackupClient.Delete(b.machine); await Refresh(); }
        catch (Exception e) { Fail(e); }
    }

    public static string Size(long n) => n switch
    {
        >= 1L << 30 => $"{n / (double)(1L << 30):0.0} GB",
        >= 1L << 20 => $"{n / (double)(1L << 20):0.0} MB",
        >= 1L << 10 => $"{n >> 10} KB",
        _ => $"{n} B",
    };
}
