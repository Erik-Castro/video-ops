# video-ops

**Download, encrypt, and play videos — securely and privately.**

A zero-dependency bash utility for downloading videos with `yt-dlp`, encrypting them with AES-256-CTR, and playing them back in Terminal (ASCII art) or Android VLC — without leaving traces.

---

## Why?

In a world of always-onlineDRM and telemetry, sometimes you just want to:

- Download a video for offline viewing
- Encrypt it so only you can play it
- Watch it on your phone without sketchy apps

`video-ops` does exactly that. Nothing more.

---

## Features

| Feature | Description |
|---------|-------------|
| **Download + Encrypt** | One command to grab and protect a video |
| **AES-256-CTR** | Military-grade encryption with PBKDF2 key derivation |
| **Auto-generated keys** | 32-byte random keys, created and stored per video |
| **Terminal playback** | ASCII art video output via `caca` — perfect for SSH sessions |
| **Android playback** | Opens directly in VLC on Android (Termux) |
| **Clean filenames** | Auto-sanitized, lowercase, 12-char max |
| **Zero temp files** | Streaming via FIFO — nothing written to disk during playback |

---

## Quick Start

```bash
# Clone
git clone https://github.com/Erik-Castro/video-ops.git
cd video-ops

# Make executable
chmod +x video-ops.sh

# Download and encrypt
./video-ops.sh download https://youtube.com/watch?v=dQw4w9WgXcQ

# Play in terminal (ASCII art)
./video-ops.sh play video.mp4.enc

# Play on Android VLC
./video-ops.sh play --android video.mp4.enc
```

---

## Commands

```
Usage: video-ops.sh <command> [options] <args>

Commands:
    download <url>       Download video with yt-dlp and encrypt it
    play <file>          Decrypt and play a video file

Options:
    -k, --key <path>     Encryption key file path (default: <filename>.key)
    -e, --ext <ext>      Output extension for download (default: auto-detect)
    --android            Open in Android VLC instead of terminal (play only)
    -h, --help           Show this help message
```

---

## How It Works

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│   yt-dlp    │ ──▶  │   openssl    │ ──▶  │  .enc file  │
│  (download) │      │ (encrypt)    │      │ + .key file │
└─────────────┘      └──────────────┘      └─────────────┘

Playback (Terminal):
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│   openssl   │ ──▶  │    cvlc      │ ──▶  │  🖥️ ASCII  │
│  (decrypt)  │      │  (caca)      │      │   output    │
└─────────────┘      └──────────────┘      └─────────────┘

Playback (Android):
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│   openssl   │ ──▶  │ FIFO + HTTP  │ ──▶  │ Android VLC │
│  (decrypt)  │      │   server     │      │  (stream)   │
└─────────────┘      └──────────────┘      └─────────────┘
```

---

## Requirements

| Dependency | Purpose |
|------------|---------|
| `yt-dlp` | Video downloading |
| `openssl` | Encryption/decryption |
| `cvlc` | Terminal playback (VLC command-line) |
| `python3` | HTTP server for Android playback |
| `termux-api` | Android integration (optional) |

---

## Examples

```bash
# Download with custom key
./video-ops.sh download -k my-secret.key https://vimeo.com/123456

# Play with custom key
./video-ops.sh play -k my-secret.key video.mp4.enc

# Download forces mp4 output
./video-ops.sh download -e mp4 https://youtube.com/watch?v=xxx

# Android playback with custom key
./video-ops.sh play -k my.key --android video.mp4.enc
```

---

## Security Notes

- **Keys are files** — keep your `.key` files safe and separate from `.enc` files
- **AES-256-CTR** — strong encryption, but no authentication (see [Known Limitations](#known-limitations))
- **PBKDF2** — 320,000 iterations for key derivation
- **No key recovery** — lose the key, lose the video

---

## Known Limitations

- No authenticated encryption (AES-CTR doesn't verify integrity)
- Single-file encryption only (no playlists/batch)
- FIFO-based streaming requires both processes alive simultaneously
- Android playback assumes VLC is installed

---

## Contributing

Contributions are welcome! Here's how:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-thing`)
3. Commit your changes (`git commit -m 'Add amazing thing'`)
4. Push to the branch (`git push origin feature/amazing-thing`)
5. Open a Pull Request

**Ideas for contributions:**
- Batch download/encrypt
- Key rotation support
- Remote key storage
- Progress bar for downloads
- Subtitle support
- macOS compatibility

---

## Disclaimer

> **This software is provided "as is", without warranty of any kind.**
>
> The authors are not responsible for any misuse of this tool. Users are solely responsible for ensuring they have the right to download and encrypt any content.
>
> This tool is intended for **personal, legal use only**. Respect copyright laws in your jurisdiction.
>
> **Encryption does not equal anonymity.** This tool encrypts files locally — it does not hide your IP, browsing activity, or identity from your ISP or network administrator.

---

## License

MIT — do whatever you want, just don't blame us.

---

## Acknowledgments

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — the download engine
- [VLC](https://www.videolan.org/) — universal media player
- [libcaca](https://caca.zoy.org/wiki/libcaca) — ASCII art rendering

---

<p align="center">
  <i>Built with ❤️ and paranoia.</i>
</p>
