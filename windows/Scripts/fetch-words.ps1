# Tải danh sách từ tiếng Anh (thay /usr/share/dict/words của macOS) vào ScreenTranslator/Resources/words.txt.
# App dùng để phân biệt câu ngắn thật ("No.", "Run!") với chữ OCR vô nghĩa ("imph", "impr"). Thiếu file thì app vẫn chạy.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$dest = Join-Path $PSScriptRoot "..\ScreenTranslator\Resources\words.txt"
if (Test-Path $dest) { Write-Host "words.txt already present"; exit 0 }
$url = "https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt"
Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
Write-Host "-> $dest ($((Get-Item $dest).Length / 1MB -as [int]) MB)"
