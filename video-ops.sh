#!/usr/bin/env bash
set -euo pipefail
umask 077

KEY_PATH=""
EXT=""
OUTPUT_NAME=""
ACTION=""
ANDROID_MODE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options] <args>

Commands:
    download <url>       Download video with yt-dlp and encrypt it
    play <file>          Decrypt and play a video file
    stop                 Kill lingering server/decrypt processes

Options:
    -k, --key <path>     Encryption key file path (default: <filename>.key)
    -e, --ext <ext>      Output extension for download (default: auto-detect)
    -o, --output <name>  Output filename base (download only, default: auto from title)
    --android            Open in Android VLC instead of terminal (play only)
    -h, --help           Show this help message

Examples:
    $(basename "$0") download https://youtube.com/watch?v=xxx
    $(basename "$0") download -k my.key https://youtube.com/watch?v=xxx
    $(basename "$0") download -o myvideo https://youtube.com/watch?v=xxx
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
    local output_name="${4:-}"

    [[ -z "$url" ]] && die "URL is required for download"
    [[ "$url" != http* ]] && die "Invalid URL: $url"

    if [[ -z "$ext" ]]; then
        ext=$(yt-dlp --print requested_formats[0] "$url" 2>/dev/null || echo "")
        [[ -z "$ext" || "$ext" == "None" ]] && ext=$(yt-dlp --print ext "$url" 2>/dev/null || echo "mp4")
    fi

    local name
    if [[ -n "$output_name" ]]; then
        name="$output_name"
    else
        name=$(yt-dlp --print title "$url" 2>/dev/null \
            | tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-zA-Z0-9_-]/_/g; s/__*/_/g; s/^_//; s/_$//' \
            | cut -c1-12 \
            || echo "video")
    fi
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
    rm -f "${__urlfile:-}"
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
    __fifo="${TMPDIR:-/tmp}/video-ops-$$-$(date +%s).fifo"
    __urlfile="${TMPDIR:-/tmp}/video-ops-$$-$(date +%s).url"
    trap __android_cleanup EXIT

    mkfifo "$__fifo"

    echo "Starting decryption..."
    setsid openssl enc -a -d -aes-256-ctr -iter 320000 -pbkdf2 \
        -pass "file:${keyfile}" \
        -in "$infile" > "$__fifo" 2>/dev/null &
    local openssl_pid=$!
    disown "$openssl_pid"

    echo "Starting HTTP server..."
    local media_ext="${infile##*.}"
    media_ext="${media_ext%.enc}"
    setsid python3 -c "
import sys, mimetypes
from http.server import HTTPServer, BaseHTTPRequestHandler

class StreamHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        mime = mimetypes.guess_type(f'file.{sys.argv[3]}')[0] or 'video/mp4'
        self.send_header('Content-Type', mime)
        self.end_headers()
        try:
            with open(sys.argv[1], 'rb') as f:
                while True:
                    data = f.read(4096)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        pass

class QuietServer(HTTPServer):
    def handle_error(self, request, client_address):
        pass

server = QuietServer(('127.0.0.1', 0), StreamHandler)
with open(sys.argv[2], 'w') as f:
    f.write(f'http://127.0.0.1:{server.server_address[1]}')
server.serve_forever()
" "$__fifo" "$__urlfile" "$media_ext" 2>/dev/null &
    local py_pid=$!
    disown "$py_pid"

    local url=""
    url=$(wait_for_url "$__urlfile")

    [[ -z "$url" ]] && die "Failed to start HTTP server"

    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  Streaming: $url"
    echo "║  Server PID: $py_pid"
    echo "║  Decrypt PID: $openssl_pid"
    echo "║"
    echo "║  Press Ctrl+C — playback continues!"
    echo "║  To stop: kill $py_pid $openssl_pid"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    if command -v am &>/dev/null; then
        am start -n org.videolan.vlc/.gui.video.VideoPlayerActivity -d "$url" 2>/dev/null \
            || am start -a android.intent.action.VIEW -d "$url" 2>/dev/null
    elif command -v termux-open &>/dev/null; then
        termux-open "$url"
    else
        die "No way to open Android player (am or termux-open not found)"
    fi
}

do_stop() {
    local pids=()
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(pgrep -f "openssl enc.*aes-256-ctr" 2>/dev/null || true)
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(pgrep -f "python3 -c.*HTTPServer" 2>/dev/null || true)

    if (( ${#pids[@]} == 0 )); then
        echo "No lingering video-ops processes found."
        return
    fi

    # Deduplicate
    local unique_pids=()
    for pid in "${pids[@]}"; do
        [[ ! " ${unique_pids[*]:-} " =~ " $pid " ]] && unique_pids+=("$pid")
    done
    pids=("${unique_pids[@]}")

    echo "Found ${#pids[@]} process(es):"
    for pid in "${pids[@]}"; do
        local cmd
        cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "unknown")
        echo "  PID $pid: $cmd"
    done

    read -r -p "Kill all? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for pid in "${pids[@]}"; do
            kill "$pid" 2>/dev/null && echo "Killed $pid" || echo "Failed to kill $pid"
        done
        rm -f "${TMPDIR:-/tmp}"/video-ops-*.fifo "${TMPDIR:-/tmp}"/video-ops-*.url
        echo "Cleanup complete."
    else
        echo "Aborted."
    fi
}

main() {
    check_deps

    (( $# == 0 )) && usage

    ACTION="$1"; shift

    case "$ACTION" in
        download)
            while (( $# > 0 )); do
                case "$1" in
                    -k|--key)    KEY_PATH="$2"; shift 2 ;;
                    -e|--ext)    EXT="$2"; shift 2 ;;
                    -o|--output) OUTPUT_NAME="$2"; shift 2 ;;
                    -h|--help)   usage ;;
                    -*)          die "Unknown option: $1" ;;
                    *)           break ;;
                esac
            done
            [[ -z "${1:-}" ]] && die "URL is required"
            do_download "$1" "$KEY_PATH" "$EXT" "$OUTPUT_NAME"
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
        stop)       do_stop ;;
        -h|--help|help) usage ;;
        *) die "Unknown command: $ACTION (use 'download', 'play', or 'stop')" ;;
    esac
}

main "$@"
