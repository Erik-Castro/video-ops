# AGENTS.md — script

## Purpose

Video download + encryption utility using `yt-dlp` and `openssl`. Downloads videos from URLs, encrypts them with AES-256-CTR, and decrypts/plays them via VLC with ASCII output (`cvlc --interact -V caca`).

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
```

## Key behaviors

- **Auto-generated keys**: If no `-k` flag, creates `<filename>.key` with `openssl rand -base64 32`
- **Key reuse**: Won't overwrite existing key files — uses them instead
- **Extension detection**: Queries yt-dlp for format, falls back to mp4
- **Output naming**: `<title>.<ext>.enc` with corresponding `.key` file (title sanitized: max 12 chars, underscores for spaces/special chars)
- **Play pipeline**: Decrypts to stdout → pipes to VLC with caca video output (ASCII art)
- **Play --android**: Decrypts → FIFO → Python HTTP server → Android VLC (no temp files left behind)

## Conventions

- Script uses `set -euo pipefail` — fails on errors, undefined vars, pipe failures
- Key files are base64-encoded 32-byte random data
- Encrypted files use AES-256-CTR with PBKDF2 (320k iterations)
- Android playback uses FIFO + local HTTP server for zero-file streaming
