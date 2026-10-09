#!/usr/bin/env python3
"""Sinh Sources/ScreenTranslator/Core/RuntimeConfigValues.swift từ subly.local.env (không commit).

subly.local.env (ở thư mục gốc repo):
    SUBLY_SERVER=https://sub.example.com
    SUBLY_PUBKEY=<public key in ra bởi `subly-server keygen`>

Giá trị được XOR với khoá ngẫu nhiên mỗi lần build để không nằm nguyên văn trong file chạy.
Không có file env (hoặc thiếu giá trị) → sinh cấu hình rỗng: bản build đó không kiểm tra máy (bản dùng riêng).
"""
import base64
import os
import secrets
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env_path = os.path.join(root, "subly.local.env")
out_path = os.path.join(root, "Sources", "ScreenTranslator", "Core", "RuntimeConfigValues.swift")

values = {}
if os.path.exists(env_path):
    for line in open(env_path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            values[k.strip()] = v.strip()

server = values.get("SUBLY_SERVER", "").rstrip("/")
pubkey = values.get("SUBLY_PUBKEY", "")
if server or pubkey:
    if not server.startswith("https://"):
        sys.exit("gen_runtime_config: SUBLY_SERVER phải bắt đầu bằng https://")
    try:
        raw = base64.urlsafe_b64decode(pubkey + "=" * (-len(pubkey) % 4))
    except Exception:
        raw = b""
    if len(raw) != 32:
        sys.exit("gen_runtime_config: SUBLY_PUBKEY không phải public key Ed25519 (base64url, 32 byte)")
else:
    raw = b""

key = secrets.token_bytes(48)


def enc(data: bytes) -> str:
    return ", ".join(str(b ^ key[i % len(key)]) for i, b in enumerate(data))


src = f"""// Sinh tự động bởi Scripts/gen_runtime_config.py, không sửa tay, không commit.
enum RuntimeConfigValues {{
    static let k: [UInt8] = [{", ".join(str(b) for b in key)}]
    static let a: [UInt8] = [{enc(server.encode())}]
    static let b: [UInt8] = [{enc(raw)}]
}}
"""
os.makedirs(os.path.dirname(out_path), exist_ok=True)
old = open(out_path, encoding="utf-8").read() if os.path.exists(out_path) else None
# Không có cấu hình và file đã là cấu hình rỗng → giữ nguyên để khỏi biên dịch lại. Có cấu hình → luôn ghi lại.
if server or old is None or "a: [UInt8] = []" not in old:
    open(out_path, "w", encoding="utf-8").write(src)
print("gen_runtime_config:", "kiểm tra máy BẬT (" + server + ")" if server else "kiểm tra máy TẮT (không có subly.local.env)")
