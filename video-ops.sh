#!/usr/bin/env bash
set -euo pipefail
umask 077

KEY_PATH=""
EXT=""
OUTPUT_NAME=""
ACTION=""
ANDROID_MODE=0

# Stream options
STREAM_PORT=8080
STREAM_PROTOCOL="http"
STREAM_TRANSCODE=""
STREAM_BITRATE=2000
STREAM_AUDIO_CODEC="aac"
STREAM_NAME=""
STREAM_TTL=1
STREAM_DST=""
STREAM_DUPLICATE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options] <args>

Commands:
    download <url>       Download video with yt-dlp and encrypt it
    play <file>          Decrypt and play a video file
    stream <file>        Decrypt and stream over LAN (HTTP/RTSP/RTP)
    stop                 Kill lingering server/decrypt processes

Options:
    -k, --key <path>     Encryption key file path (default: <filename>.key)
    -e, --ext <ext>      Output extension for download (default: auto-detect)
    -o, --output <name>  Output filename base (download only, default: auto from title)
    --android            Open in Android VLC instead of terminal (play only)
    -h, --help           Show this help message

Stream Options:
    -p, --port <port>    Server port (default: 8080)
    --protocol <proto>   http, rtsp, or rtp (default: http)
    --transcode <codec>  Video codec: h264, h265 (default: none)
    --bitrate <kbps>     Bitrate in kbps (default: 2000)
    --audio-codec <c>    Audio codec: aac, mp3, vorbis (default: aac)
    --name <name>        Stream name for RTSP/SAP
    --dst <addr>         Multicast address for RTP (default: 239.255.12.42)
    --ttl <n>            Multicast TTL (default: 1)
    --duplicate          Show local display + stream

Examples:
    $(basename "$0") download https://youtube.com/watch?v=xxx
    $(basename "$0") download -k my.key https://youtube.com/watch?v=xxx
    $(basename "$0") download -o myvideo https://youtube.com/watch?v=xxx
    $(basename "$0") play video.mp4
    $(basename "$0") play -k my.key video.mp4
    $(basename "$0") play --android video.mp4
    $(basename "$0") stream video.mp4.enc
    $(basename "$0") stream --port 9090 --transcode h264 video.mp4.enc
    $(basename "$0") stream --protocol rtsp --name myvideo video.mp4.enc
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

build_sout() {
    local protocol="$1"
    local port="$2"
    local transcode="$3"
    local bitrate="$4"
    local audio_codec="$5"
    local name="$6"
    local dst="$7"
    local ttl="$8"
    local duplicate="$9"

    local sout=""
    local trans_part=""
    local stream_part=""

    if [[ -n "$transcode" ]]; then
        trans_part="transcode{vcodec=${transcode},vb=${bitrate},acodec=${audio_codec}}"
    fi

    case "$protocol" in
        http)
            stream_part="std{access=http,mux=ts,dst=:${port}}"
            ;;
        rtsp)
            local rtsp_name="${name:-stream}"
            stream_part="rtp{dst=0.0.0.0,port=${port},sdp=rtsp://:${port}/${rtsp_name}}"
            ;;
        rtp)
            local rtp_dst="${dst:-239.255.12.42}"
            local sdp_part=""
            if [[ -n "$name" ]]; then
                sdp_part=",sdp=sap,name=\"${name}\""
            fi
            stream_part="rtp{mux=ts,dst=${rtp_dst},port=${port}${sdp_part},ttl=${ttl}}"
            ;;
        *)
            die "Unknown protocol: $protocol (use http, rtsp, or rtp)"
            ;;
    esac

    if [[ -n "$trans_part" ]]; then
        sout="#transcode{${trans_part}}:${stream_part}"
    else
        sout="#${stream_part}"
    fi

    if [[ "$duplicate" -eq 1 ]]; then
        sout="#duplicate{dst=display,dst=${sout#?}}"
    fi

    echo "$sout"
}

do_stream() {
    local infile="$1"
    local keyfile="$2"

    [[ -z "$infile" ]] && die "File is required for stream"
    [[ ! -f "$infile" ]] && die "File not found: $infile"

    if [[ -z "$keyfile" ]]; then
        keyfile="${infile%.*}"
        keyfile="${keyfile%.enc}"
        keyfile="${keyfile}.key"
    fi
    [[ ! -f "$keyfile" ]] && die "Key file not found: $keyfile"

    local sout
    sout=$(build_sout "$STREAM_PROTOCOL" "$STREAM_PORT" "$STREAM_TRANSCODE" \
        "$STREAM_BITRATE" "$STREAM_AUDIO_CODEC" "$STREAM_NAME" "$STREAM_DST" \
        "$STREAM_TTL" "$STREAM_DUPLICATE")

    echo "Starting stream..."
    echo "  Protocol: $STREAM_PROTOCOL"
    echo "  Port: $STREAM_PORT"
    [[ -n "$STREAM_TRANSCODE" ]] && echo "  Transcode: ${STREAM_TRANSCODE} @ ${STREAM_BITRATE}kbps"
    echo "  Sout: $sout"
    echo ""

    local lan_ip=""
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

    local url=""
    case "$STREAM_PROTOCOL" in
        http)  url="http://${lan_ip}:${STREAM_PORT}" ;;
        rtsp)  url="rtsp://${lan_ip}:${STREAM_PORT}/${STREAM_NAME:-stream}" ;;
        rtp)   url="rtp://@${STREAM_DST:-239.255.12.42}:${STREAM_PORT}" ;;
    esac

    echo "╔══════════════════════════════════════════════════╗"
    echo "║  Stream URL: $url"
    echo "║"
    echo "║  Connect with:"
    echo "║    cvlc $url"
    echo "║    vlc $url"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo "Press Ctrl+C to stop streaming."
    echo ""

    openssl enc -a -d -aes-256-ctr -iter 320000 -pbkdf2 \
        -pass "file:${keyfile}" \
        -in "$infile" \
        | cvlc --sout "$sout" --no-video-title-show -
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
        am start -a android.intent.action.VIEW \
            -d "$url" \
            -t "video/*" \
            --ez "extra_playback" true 2>/dev/null \
            || am start -a android.intent.action.VIEW -d "$url" 2>/dev/null \
            || echo "Could not open VLC. Open manually: $url"
    elif command -v termux-open &>/dev/null; then
        termux-open "$url"
    else
        echo "Open in Android VLC: $url"
    fi
}

do_stop() {
    local pids=()
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(pgrep -f "openssl enc.*aes-256-ctr" 2>/dev/null || true)
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(pgrep -f "cvlc.*sout" 2>/dev/null || true)

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
        stream)
            while (( $# > 0 )); do
                case "$1" in
                    -k|--key)        KEY_PATH="$2"; shift 2 ;;
                    -p|--port)       STREAM_PORT="$2"; shift 2 ;;
                    --protocol)      STREAM_PROTOCOL="$2"; shift 2 ;;
                    --transcode)     STREAM_TRANSCODE="$2"; shift 2 ;;
                    --bitrate)       STREAM_BITRATE="$2"; shift 2 ;;
                    --audio-codec)   STREAM_AUDIO_CODEC="$2"; shift 2 ;;
                    --name)          STREAM_NAME="$2"; shift 2 ;;
                    --dst)           STREAM_DST="$2"; shift 2 ;;
                    --ttl)           STREAM_TTL="$2"; shift 2 ;;
                    --duplicate)     STREAM_DUPLICATE=1; shift ;;
                    -h|--help)       usage ;;
                    -*)              die "Unknown option: $1" ;;
                    *)               break ;;
                esac
            done
            [[ -z "${1:-}" ]] && die "File is required"
            do_stream "$1" "$KEY_PATH"
            ;;
        stop)       do_stop ;;
        -h|--help|help) usage ;;
        *) die "Unknown command: $ACTION (use 'download', 'play', 'stream', or 'stop')" ;;
    esac
}

main "$@"
