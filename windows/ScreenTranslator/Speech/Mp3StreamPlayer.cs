using System;
using System.IO;
using NAudio.Wave;

namespace ScreenTranslator;

/// Phát MP3 ngay khi từng mẩu tới (Edge TTS streaming): tách frame MP3 → giải mã (ACM) → PCM → BufferedWaveProvider.
public sealed class Mp3StreamPlayer : IDisposable
{
    readonly object lk = new();
    readonly MemoryStream pending = new();
    IMp3FrameDecompressor? decoder;
    BufferedWaveProvider? buffer;
    WaveOutEvent? output;
    WaveFormat? pcmFormat;
    readonly byte[] decodeBuf = new byte[16384 * 4];
    float _volume = 1;
    DateTime lastFeed = DateTime.MinValue;
    /// Số frame đã xếp vào bộ phát kể từ `Begin` (0 = streaming không giải mã được).
    public int scheduledFrames { get; private set; }
    public DateTime busyUntil { get; private set; } = DateTime.MinValue;

    public float volume
    {
        get => _volume;
        set { _volume = value; lock (lk) if (output != null) output.Volume = Math.Clamp(value, 0, 1); }
    }

    /// Bắt đầu một câu mới. `flush` = bỏ âm thanh đang phát.
    public void Begin(bool flush)
    {
        lock (lk)
        {
            pending.SetLength(0);
            scheduledFrames = 0;
            if (flush) { buffer?.ClearBuffer(); busyUntil = DateTime.MinValue; }
        }
    }

    public void Feed(byte[] chunk)
    {
        lock (lk)
        {
            lastFeed = DateTime.UtcNow;
            // Ghép vào phần dư của lần trước rồi đọc từng frame trọn vẹn.
            pending.Seek(0, SeekOrigin.End);
            pending.Write(chunk, 0, chunk.Length);
            pending.Position = 0;
            while (true)
            {
                long start = pending.Position;
                Mp3Frame? frame;
                try { frame = Mp3Frame.LoadFromStream(pending); }
                catch { frame = null; }
                if (frame == null || pending.Position > pending.Length) { pending.Position = start; break; }
                DecodeFrame(frame);
            }
            // Giữ lại phần dư chưa đủ một frame.
            var rest = pending.Length - pending.Position;
            var tail = new byte[rest];
            pending.Read(tail, 0, (int)rest);
            pending.SetLength(0);
            pending.Write(tail, 0, tail.Length);
        }
    }

    void DecodeFrame(Mp3Frame frame)
    {
        if (decoder == null)
        {
            var mp3Format = new Mp3WaveFormat(frame.SampleRate, frame.ChannelMode == ChannelMode.Mono ? 1 : 2, frame.FrameLength, frame.BitRate);
            decoder = new AcmMp3FrameDecompressor(mp3Format);
            pcmFormat = decoder.OutputFormat;
        }
        if (buffer == null || output == null)
        {
            buffer = new BufferedWaveProvider(pcmFormat!) { BufferDuration = TimeSpan.FromMinutes(5), DiscardOnBufferOverflow = true, ReadFully = true };
            output = new WaveOutEvent { DesiredLatency = 120, NumberOfBuffers = 3 };
            output.Init(buffer);
            output.Volume = Math.Clamp(_volume, 0, 1);
            output.Play();
        }
        int n;
        try { n = decoder.DecompressFrame(frame, decodeBuf, 0); }
        catch (Exception e) { Log.Warn($"MP3 decode lỗi: {e.Message}"); return; }
        if (n <= 0) return;
        buffer.AddSamples(decodeBuf, 0, n);
        scheduledFrames++;
        var dur = TimeSpan.FromSeconds((double)n / pcmFormat!.AverageBytesPerSecond);
        var st = busyUntil > DateTime.UtcNow ? busyUntil : DateTime.UtcNow;
        busyUntil = st + dur;
        if (output.PlaybackState != PlaybackState.Playing) output.Play();
    }

    /// Lưới an toàn: phát cả file MP3 (khi streaming không ra âm thanh).
    public void PlayWhole(byte[] mp3)
    {
        Begin(false);
        Feed(mp3);
    }

    public void Stop()
    {
        lock (lk)
        {
            pending.SetLength(0);
            buffer?.ClearBuffer();
            busyUntil = DateTime.MinValue;
        }
    }

    public void Dispose()
    {
        lock (lk)
        {
            output?.Stop(); output?.Dispose(); output = null;
            decoder?.Dispose(); decoder = null;
            buffer = null;
        }
    }
}
