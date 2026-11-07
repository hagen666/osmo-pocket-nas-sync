#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
大疆 3 秒视频 → 苹果实况照片（Live Photo）

原理：
  苹果实况照片 = 一对文件
    IMG_xxxx.JPG   静态图，EXIF 的 Apple MakerNote tag 17 = ContentIdentifier
    IMG_xxxx.MOV   3 秒视频，元数据 com.apple.quicktime.content.identifier = 同一个 UUID
  两个 UUID 相同 → iOS 相册自动识别为实况照片

用法：
  python3 make_livephoto.py <输入MP4> <输出目录> <输出基础名>

示例：
  python3 make_livephoto.py a.mp4 ./out IMG_0001
"""
import os
import struct
import subprocess
import sys
import uuid

from PIL import Image


def apple_makernote(content_id: str) -> bytes:
    """构造最小 Apple MakerNote，只含 tag 0x0011 (ContentIdentifier)"""
    payload = content_id.encode("ascii") + b"\x00"
    # 头部 14 字节： "Apple iOS\0" + 版本(2) + "MM"(大端)
    hdr = b"Apple iOS\x00" + b"\x00\x01" + b"MM"
    ifd = struct.pack(">H", 1)                              # 1 个条目
    ifd += struct.pack(">HHI", 0x0011, 0x0002, len(payload))  # tag=17, ASCII, 长度
    ifd += struct.pack(">I", len(hdr) + 18)                 # 值偏移：从 MakerNote 起点算
    ifd += struct.pack(">I", 0)                             # 下一个 IFD = 0
    return hdr + ifd + payload


def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"命令失败: {cmd}\n{r.stderr[-800:]}")
    return r.stdout


def make(input_mp4, out_dir, base_name, dt_string):
    os.makedirs(out_dir, exist_ok=True)
    jpg = os.path.join(out_dir, base_name + ".JPG")
    mov = os.path.join(out_dir, base_name + ".MOV")
    cid = str(uuid.uuid4()).upper()

    # 1) 提取关键帧
    run(
        f'ffmpeg -y -loglevel error -ss 0.3 -i "{input_mp4}" -frames:v 1 '
        f'-vf "scale=1920:1080:flags=lanczos" -q:v 2 "{jpg}"'
    )

    # 2) 转码 MOV（H.264 8-bit，最大兼容）
    run(
        f'ffmpeg -y -loglevel error -i "{input_mp4}" '
        f'-c:v libx264 -profile:v high -pix_fmt yuv420p -crf 20 -preset medium '
        f'-vf "scale=1920:1080:flags=lanczos" -r 30 '
        f'-c:a aac -b:a 128k -movflags +faststart "{mov}"'
    )

    # 3) JPG 注入 MakerNote + 元数据
    exif = Image.open(jpg).getexif()
    exif[0x010F] = "Apple"
    exif[0x0110] = "iPhone 15 Pro"
    exif[0x0131] = "17.0"
    exif[0x0132] = dt_string
    exif[0x9003] = dt_string
    exif[0x927C] = apple_makernote(cid)
    Image.open(jpg).save(jpg, exif=exif.tobytes(), quality=95)

    # 4) MOV 写 ContentIdentifier
    run(f'exiftool -overwrite_original -q -Keys:ContentIdentifier="{cid}" "{mov}"')

    # 5) 校验
    j_cid = run(f'exiftool -s3 -ContentIdentifier "{jpg}"').strip()
    m_cid = run(f'exiftool -s3 -ContentIdentifier "{mov}"').strip()
    ok = bool(j_cid) and j_cid == m_cid
    print(f"  {'✅' if ok else '❌'} {base_name}  UUID={cid}  "
          f"jpg={os.path.getsize(jpg)//1024}KB mov={os.path.getsize(mov)//1024}KB")
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    src, outdir, base = sys.argv[1], sys.argv[2], sys.argv[3]
    dt = sys.argv[4] if len(sys.argv) > 4 else "2026:01:01 00:00:00"
    sys.exit(0 if make(src, outdir, base, dt) else 1)
