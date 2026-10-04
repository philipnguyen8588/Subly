using System;
using System.IO;
using System.Runtime.InteropServices;

namespace ScreenTranslator;

/// P/Invoke tới st_chiaki.dll (windows/native/st_chiaki: cầu nối libchiaki + giải mã H.264 bằng FFmpeg, dựng bằng Scripts/build-chiaki.sh).
static class ChiakiNative
{
    const string Dll = "st_chiaki";

    public const int ST_EVENT_LOG = 0, ST_EVENT_CONNECTED = 1, ST_EVENT_QUIT = 2, ST_EVENT_PIN_REQUEST = 3;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void VideoCb(IntPtr buf, UIntPtr size, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void EventCb(int type, IntPtr msg, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void RegistCb(int ok, IntPtr nickname, IntPtr mac, IntPtr registKey, IntPtr rpKey, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void DiscoveryCb(IntPtr addr, IntPtr name, IntPtr hostId, int isPs5, int state, IntPtr user);

    /// resolution: 1=360p 2=540p 3=720p 4=1080p; fps 30|60; hevc 0=H264 1=H265
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr st_session_start([MarshalAs(UnmanagedType.LPUTF8Str)] string host, int ps5, byte[] registKey, byte[] morning,
        byte[] accountId, int resolution, int fps, int hevc, VideoCb videoCb, EventCb eventCb, IntPtr user);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void st_session_stop(IntPtr s);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void st_session_request_idr(IntPtr s);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void st_session_set_pin(IntPtr s, [MarshalAs(UnmanagedType.LPUTF8Str)] string pin);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr st_regist_start([MarshalAs(UnmanagedType.LPUTF8Str)] string host, int ps5, byte[] accountId, uint pin,
        RegistCb cb, EventCb logCb, IntPtr user);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void st_regist_finish(IntPtr r);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int st_discover([MarshalAs(UnmanagedType.LPUTF8Str)] string host, int timeoutMs, DiscoveryCb cb, IntPtr user);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int st_wakeup([MarshalAs(UnmanagedType.LPUTF8Str)] string host, byte[] registKey, int ps5);

    // Giải mã H.264 (Annex-B) → BGRA
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr st_decoder_new();
    /// 1 = có khung mới, 0 = chưa có khung (cần thêm dữ liệu), &lt;0 = lỗi
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern int st_decoder_decode(IntPtr d, IntPtr buf, UIntPtr size);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr st_decoder_frame(IntPtr d, out int width, out int height, out int stride);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void st_decoder_free(IntPtr d);

    static bool? available;
    public static string? LoadError;
    public static bool Available
    {
        get
        {
            if (available is bool b) return b;
            var path = Path.Combine(AppPaths.AppDir, Dll + ".dll");
            try
            {
                available = File.Exists(path) && NativeLibrary.TryLoad(path, out _);
                if (available != true)
                    LoadError = File.Exists(path) ? "Không nạp được st_chiaki.dll (thiếu DLL phụ thuộc?)" : "Chưa dựng thư viện PS5 (st_chiaki.dll). Chạy windows/Scripts/build-chiaki.sh trong MSYS2 MINGW64.";
            }
            catch (Exception e) { available = false; LoadError = e.Message; }
            return available.Value;
        }
    }
}
