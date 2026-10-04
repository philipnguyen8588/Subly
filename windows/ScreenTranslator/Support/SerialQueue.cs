using System;
using System.Collections.Concurrent;
using System.Threading;

namespace ScreenTranslator;

/// Hàng đợi tuần tự trên một thread riêng (thay DispatchQueue serial của macOS).
public sealed class SerialQueue : IDisposable
{
    readonly BlockingCollection<Action> work = new();
    readonly Thread thread;

    public SerialQueue(string name, ThreadPriority priority = ThreadPriority.Normal)
    {
        thread = new Thread(() =>
        {
            foreach (var a in work.GetConsumingEnumerable())
            {
                try { a(); }
                catch (Exception e) { Log.Error($"{name}: {e}"); }
            }
        }) { IsBackground = true, Name = name, Priority = priority };
        thread.Start();
    }

    public void Async(Action a)
    {
        try { if (!work.IsAddingCompleted) work.Add(a); }
        catch (InvalidOperationException) { }   // hàng đợi đã đóng
    }

    public void Dispose() => work.CompleteAdding();
}
