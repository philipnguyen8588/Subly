using System;
using NAudio.Wave;

namespace ScreenTranslator;

/// Phát mẫu Float32 mono (giọng AI offline / giọng Windows) qua NAudio, đọc nối tiếp hoặc ngắt câu đang đọc.
public sealed class PcmStreamPlayer : IDisposable
{
    WaveOutEvent? output;
    BufferedWaveProvider? buffer;
    int rate;
    readonly object lk = new();
    float _volume = 1;
    /// Ước lượng thời điểm phát xong phần đã xếp hàng.
    public DateTime busyUntil { get; private set; } = DateTime.MinValue;
    public bool isBusy => busyUntil > DateTime.UtcNow;

    public float volume
    {
        get => _volume;
        set { _volume = value; lock (lk) if (output != null) output.Volume = Math.Clamp(value, 0, 1); }
    }

    void Ensure(int sampleRate)
    {
        if (output != null && rate == sampleRate) return;
        output?.Stop(); output?.Dispose();
        rate = sampleRate;
        buffer = new BufferedWaveProvider(new WaveFormat(sampleRate, 16, 1))
        {
            BufferDuration = TimeSpan.FromMinutes(5),
            DiscardOnBufferOverflow = true,
            ReadFully = true,
        };
        output = new WaveOutEvent { DesiredLatency = 120, NumberOfBuffers = 3 };
        output.Init(buffer);
        output.Volume = Math.Clamp(_volume, 0, 1);
        output.Play();
    }

    /// `flush` = bỏ phần đang đọc dở, phát câu mới ngay.
    public void Play(float[] samples, int sampleRate, bool flush)
    {
        lock (lk)
        {
            Ensure(sampleRate);
            if (flush) { buffer!.ClearBuffer(); busyUntil = DateTime.MinValue; }
            var bytes = new byte[samples.Length * 2];
            for (int i = 0; i < samples.Length; i++)
            {
                var s = (short)Math.Clamp((int)(samples[i] * 32767f), short.MinValue, short.MaxValue);
                bytes[2 * i] = (byte)s; bytes[2 * i + 1] = (byte)(s >> 8);
            }
            buffer!.AddSamples(bytes, 0, bytes.Length);
            var dur = TimeSpan.FromSeconds((double)samples.Length / sampleRate);
            var start = busyUntil > DateTime.UtcNow ? busyUntil : DateTime.UtcNow;
            busyUntil = start + dur;
            if (output!.PlaybackState != PlaybackState.Playing) output.Play();
        }
    }

    /// Phát PCM 16-bit (đã có sẵn byte).
    public void PlayPcm16(byte[] pcm, int sampleRate, bool flush)
    {
        lock (lk)
        {
            Ensure(sampleRate);
            if (flush) { buffer!.ClearBuffer(); busyUntil = DateTime.MinValue; }
            buffer!.AddSamples(pcm, 0, pcm.Length);
            var dur = TimeSpan.FromSeconds(pcm.Length / 2.0 / sampleRate);
            var start = busyUntil > DateTime.UtcNow ? busyUntil : DateTime.UtcNow;
            busyUntil = start + dur;
            if (output!.PlaybackState != PlaybackState.Playing) output.Play();
        }
    }

    public void Stop()
    {
        lock (lk) { buffer?.ClearBuffer(); busyUntil = DateTime.MinValue; }
    }

    public void Dispose()
    {
        lock (lk) { output?.Stop(); output?.Dispose(); output = null; buffer = null; }
    }
}
