using System;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ScreenTranslator;

/// Khung hình BGRA 32-bit trong bộ nhớ (tương đương CVPixelBuffer BGRA trên macOS).
public sealed class Frame
{
    public readonly byte[] Data;
    public readonly int Width, Height, Stride;
    public readonly DateTime Time = DateTime.UtcNow;

    public Frame(byte[] data, int width, int height, int stride)
    {
        Data = data; Width = width; Height = height; Stride = stride;
    }

    public Frame(int width, int height) : this(new byte[width * height * 4], width, height, width * 4) { }

    /// Cắt một vùng theo tỉ lệ 0...1 (gốc trên-trái).
    public Frame? CropNormalized(RectD n)
    {
        int x = (int)Math.Round(Math.Clamp(n.X, 0, 1) * Width);
        int y = (int)Math.Round(Math.Clamp(n.Y, 0, 1) * Height);
        int w = (int)Math.Round(Math.Clamp(n.Width, 0, 1) * Width);
        int h = (int)Math.Round(Math.Clamp(n.Height, 0, 1) * Height);
        return Crop(x, y, w, h);
    }

    public Frame? Crop(int x, int y, int w, int h)
    {
        x = Math.Clamp(x, 0, Width); y = Math.Clamp(y, 0, Height);
        w = Math.Min(w, Width - x); h = Math.Min(h, Height - y);
        if (w < 2 || h < 2) return null;
        var f = new Frame(w, h);
        for (int row = 0; row < h; row++)
            Buffer.BlockCopy(Data, (y + row) * Stride + x * 4, f.Data, row * f.Stride, w * 4);
        return f;
    }

    /// Thu nhỏ (lấy mẫu gần nhất + trung bình 2×2 khi thu nhiều) để bề ngang ≤ maxWidth.
    public Frame Downscale(int maxWidth)
    {
        if (Width <= maxWidth) return this;
        double s = (double)maxWidth / Width;
        int nw = Math.Max(1, (int)(Width * s)), nh = Math.Max(1, (int)(Height * s));
        var bs = ToBitmapSource();
        var tb = new TransformedBitmap(bs, new ScaleTransform(s, s));
        return FromBitmapSource(tb);
    }

    /// Phóng to bằng nội suy (giúp OCR đọc chữ nhỏ).
    public Frame Scale(double s)
    {
        if (Math.Abs(s - 1) < 0.01) return this;
        var tb = new TransformedBitmap(ToBitmapSource(), new ScaleTransform(s, s));
        return FromBitmapSource(tb);
    }

    public BitmapSource ToBitmapSource()
    {
        var bs = BitmapSource.Create(Width, Height, 96, 96, PixelFormats.Bgra32, null, Data, Stride);
        bs.Freeze();
        return bs;
    }

    public static Frame FromBitmapSource(BitmapSource src)
    {
        if (src.Format != PixelFormats.Bgra32 && src.Format != PixelFormats.Pbgra32)
            src = new FormatConvertedBitmap(src, PixelFormats.Bgra32, null, 0);
        int w = src.PixelWidth, h = src.PixelHeight;
        var f = new Frame(w, h);
        src.CopyPixels(f.Data, f.Stride, 0);
        return f;
    }

    /// Ảnh JPEG (để lưu ảnh dịch màn hình / gửi web).
    public byte[] ToJpeg(int quality = 60, int maxWidth = 0)
    {
        BitmapSource bs = ToBitmapSource();
        if (maxWidth > 0 && Width > maxWidth)
        {
            double s = (double)maxWidth / Width;
            bs = new TransformedBitmap(bs, new ScaleTransform(s, s));
        }
        var enc = new JpegBitmapEncoder { QualityLevel = quality };
        enc.Frames.Add(BitmapFrame.Create(bs));
        using var ms = new System.IO.MemoryStream();
        enc.Save(ms);
        return ms.ToArray();
    }

    public byte[] ToPng()
    {
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(ToBitmapSource()));
        using var ms = new System.IO.MemoryStream();
        enc.Save(ms);
        return ms.ToArray();
    }
}
