#!/usr/bin/env bash
set -euo pipefail

KEY_PATH=""
EXT=""
ACTION=""
ANDROID_MODE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options] <args>

Commands:
    download <url>       Download video with yt-dlp and encrypt it
    play <file>          Decrypt and play a video file

Options:
    -k, --key <path>     Encryption key file path (default: <filename>.key)
    -e, --ext <ext>      Output extension for download (default: auto-detect)
    --android            Open in Android VLC instead of terminal (play only)
    -h, --help           Show this help message

Examples:
    $(basename "$0") download https://youtube.com/watch?v=xxx
    $(basename "$0") download -k my.key https://youtube.com/watch?v=xxx
    $(basename "$0") play video.mp4
    $(basename "$0") play -k my.key video.mp4
    $(basename "$0") play --android video.mp4
EOF
    exit 0
}

die() { echo "Error: $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in yt-dlp openssl cvlc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        die "Missing dependencies: ${missing[*]}"
    fi
}

generate_key() {
    local keyfile="$1"
    if [[ ! -f "$keyfile" ]]; then
        openssl rand -base64 32 > "$keyfile"
        echo "Key saved to: $keyfile"
    else
        echo "Using existing key: $keyfile"
    fi
}

do_download() {
    local url="$1"
    local keyfile="$2"
    local ext="$3"

    [[ -z "$url" ]] && die "URL is required for download"
    [[ "$url" != http* ]] && die "Invalid URL: $url"

    if [[ -z "$ext" ]]; then
        ext=$(yt-dlp --print requested_formats[0] "$url" 2>/dev/null || echo "")
        [[ -z "$ext" || "$ext" == "None" ]] && ext=$(yt-dlp --print ext "$url" 2>/dev/null || echo "mp4")
    fi

    local name
    name=$(yt-dlp --print title "$url" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-zA-Z0-9_-]/_/g; s/__*/_/g; s/^_//; s/_$//' \
        | cut -c1-12 \
        || echo "video")
    local base="${name}.${ext}"
    local outfile="${base}.enc"

    if [[ -z "$keyfile" ]]; then
        keyfile="${base}.key"
    fi

    generate_key "$keyfile"

    echo "Downloading and encrypting..."
    yt-dlp \
        --video-multistreams \
        --audio-multistreams \
        -f "bv*+ba/b" \
        -o- "$url" \
        | openssl enc -a -out "$outfile" \
          -aes-256-ctr -iter 320000 -pbkdf2 \
          -pass "file:${keyfile}"

    echo "Saved: $outfile"
    echo "Key: $keyfile"
}

do_play() {
    local infile="$1"
    local keyfile="$2"

    [[ -z "$infile" ]] && die "File is required for play"
    [[ ! -f "$infile" ]] && die "File not found: $infile"

    if [[ -z "$keyfile" ]]; then
        keyfile="${infile%.*}"
        keyfile="${keyfile}.key"
    fi
    [[ ! -f "$keyfile" ]] && die "Key file not found: $keyfile"

    echo "Decrypting and playing..."
    openssl enc -a -d -aes-256-ctr -iter 320000 -pbkdf2 \
        -pass "file:${keyfile}" \
        -in "$infile" \
        | cvlc --interact -V caca -
}

wait_for_url() {
    local urlfile="$1"
    local url="" attempts=0
    while [[ -z "$url" && $attempts -lt 50 ]]; do
        if [[ -f "$urlfile" ]]; then
            url=$(cat "$urlfile" 2>/dev/null || true)
        fi
        if [[ -z "$url" ]]; then
            sleep 0.1
            ((attempts++))
        fi
    done
    echo "$url"
}

__android_cleanup() {
    [[ "${__cleanup_done:-0}" -eq 1 ]] && return
    __cleanup_done=1
    echo "Cleaning up..."
    [[ -n "${__openssl_pid:-}" ]] && kill "$__openssl_pid" 2>/dev/null
    [[ -n "${__py_pid:-}" ]] && kill "$__py_pid" 2>/dev/null
    rm -f "${__fifo:-}" "${__urlfile:-}"
}

do_play_android() {
    local infile="$1"
    local keyfile="$2"

    [[ -z "$infile" ]] && die "File is required for play"
    [[ ! -f "$infile" ]] && die "File not found: $infile"

    if [[ -z "$keyfile" ]]; then
        keyfile="${infile%.*}"
        keyfile="${keyfile}.key"
    fi
    [[ ! -f "$keyfile" ]] && die "Key file not found: $keyfile"

    __cleanup_done=0
    __openssl_pid=""
    __py_pid=""
    __fifo="/tmp/video-ops-$$-$(date +%s).fifo"
    __urlfile="/tmp/video-ops-$$-$(date +%s).url"
    trap __android_cleanup EXIT INT TERM

    mkfifo "$__fifo"

    echo "Starting decryption..."
    openssl enc -a -d -aes-256-ctr -iter 320000 -pbkdf2 \
        -pass "file:${keyfile}" \
        -in "$infile" > "$__fifo" &
    __openssl_pid=$!

    echo "Starting HTTP server..."
    python3 -c "
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

class StreamHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            with open(sys.argv[1], 'rb') as f:
                while True:
                    data = f.read(65536)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
        except BrokenPipeError:
            pass

    def log_message(self, format, *args):
        pass

server = HTTPServer(('127.0.0.1', 0), StreamHandler)
with open(sys.argv[2], 'w') as f:
    f.write(f'http://127.0.0.1:{server.server_address[1]}')
server.handle_request()
server.server_close()
" "$__fifo" "$__urlfile" &
    __py_pid=$!

    local url=""
    url=$(wait_for_url "$__urlfile")

    [[ -z "$url" ]] && die "Failed to start HTTP server"

    echo "Opening: $url"
    if command -v termux-open &>/dev/null; then
        termux-open "$url"
    elif command -v am &>/dev/null; then
        am start -a android.intent.action.VIEW -d "$url" 2>/dev/null
    else
        die "No way to open Android player (termux-open or am not found)"
    fi

    wait "$__py_pid" 2>/dev/null
}

main() {
    check_deps

    (( $# == 0 )) && usage

    ACTION="$1"; shift

    case "$ACTION" in
        download)
            while (( $# > 0 )); do
                case "$1" in
                    -k|--key)  KEY_PATH="$2"; shift 2 ;;
                    -e|--ext)  EXT="$2"; shift 2 ;;
                    -h|--help) usage ;;
                    -*)        die "Unknown option: $1" ;;
                    *)         break ;;
                esac
            done
            [[ -z "${1:-}" ]] && die "URL is required"
            do_download "$1" "$KEY_PATH" "$EXT"
            ;;
        play)
            while (( $# > 0 )); do
                case "$1" in
                    -k|--key)    KEY_PATH="$2"; shift 2 ;;
                    --android)   ANDROID_MODE=1; shift ;;
                    -h|--help)   usage ;;
                    -*)          die "Unknown option: $1" ;;
                    *)           break ;;
                esac
            done
            [[ -z "${1:-}" ]] && die "File is required"
            if [[ "$ANDROID_MODE" -eq 1 ]]; then
                do_play_android "$1" "$KEY_PATH"
            else
                do_play "$1" "$KEY_PATH"
            fi
            ;;
        -h|--help|help) usage ;;
        *) die "Unknown command: $ACTION (use 'download' or 'play')" ;;
    esac
}

main "$@"
