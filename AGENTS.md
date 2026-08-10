# AGENTS.md — script

## Purpose

Video download + encryption + LAN streaming utility using `yt-dlp`, `openssl`, and `cvlc`. Downloads videos from URLs, encrypts them with AES-256-CTR, and decrypts/plays them locally or streams them over LAN.

## Dependencies

Required: `yt-dlp`, `openssl`, `cvlc` (VLC command-line)

Script checks deps on startup — will fail fast with missing command list.

## Usage

```bash
# Download and encrypt
./video-ops.sh download <url>
./video-ops.sh download -k custom.key <url>

# Decrypt and play (ASCII art mode)
./video-ops.sh play video.mp4.enc
./video-ops.sh play -k custom.key video.mp4.enc

# Decrypt and play in Android VLC (no intermediate files)
./video-ops.sh play --android video.mp4.enc
./video-ops.sh play -k custom.key --android video.mp4.enc

# Stream to LAN (HTTP)
./video-ops.sh stream video.mp4.enc
./video-ops.sh stream --port 9090 video.mp4.enc

# Stream with transcoding (lower quality for mobile)
./video-ops.sh stream --transcode h264 --bitrate 1000 video.mp4.enc

# Stream via RTSP
./video-ops.sh stream --protocol rtsp --name myvideo video.mp4.enc

# Multicast RTP broadcast
./video-ops.sh stream --protocol rtp --dst 239.255.12.42 --port 1234 video.mp4.enc

# Show local display while streaming
./video-ops.sh stream --duplicate video.mp4.enc
```

## Key behaviors

- **Auto-generated keys**: If no `-k` flag, creates `<filename>.key` with `openssl rand -base64 32`
- **Key reuse**: Won't overwrite existing key files — uses them instead
- **Extension detection**: Queries yt-dlp for format, falls back to mp4
- **Output naming**: `<title>.<ext>.enc` with corresponding `.key` file (title sanitized: max 12 chars, underscores for spaces/special chars)
- **Play pipeline**: Decrypts to stdout → pipes to VLC with caca video output (ASCII art)
- **Play --android**: Decrypts → FIFO → Python HTTP server → Android VLC (no temp files)
- **Stream**: Decrypts → pipes to cvlc `--sout` for HTTP/RTSP/RTP streaming (no temp files)
- **Zero intermediate files**: All operations use pipe-based decryption, nothing written to disk

## Stream options

| Flag | Default | Description |
|------|---------|-------------|
| `-p, --port` | 8080 | Server port |
| `--protocol` | http | http, rtsp, or rtp |
| `--transcode` | (none) | Video codec: h264, h265 |
| `--bitrate` | 2000 | Bitrate in kbps |
| `--audio-codec` | aac | aac, mp3, vorbis |
| `--name` | (auto) | Stream name for RTSP/SAP |
| `--dst` | 239.255.12.42 | Multicast address for RTP |
| `--ttl` | 1 | Multicast TTL |
| `--duplicate` | off | Show local display + stream |

## Conventions

- Script uses `set -euo pipefail` — fails on errors, undefined vars, pipe failures
- Key files are base64-encoded 32-byte random data
- Encrypted files use AES-256-CTR with PBKDF2 (320k iterations)
- All playback/streaming uses pipe-based decryption (zero temp files)
- Streaming uses VLC's `--sout` for native HTTP/RTSP/RTP support
