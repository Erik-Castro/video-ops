#!/usr/bin/env bash
set -euo pipefail

KEY_PATH=""
EXT=""
ACTION=""

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options] <args>

Commands:
    download <url>       Download video with yt-dlp and encrypt it
    play <file>          Decrypt and play a video file

Options:
    -k, --key <path>     Encryption key file path (default: <filename>.key)
    -e, --ext <ext>      Output extension for download (default: auto-detect)
    -h, --help           Show this help message

Examples:
    $(basename "$0") download https://youtube.com/watch?v=xxx
    $(basename "$0") download -k my.key https://youtube.com/watch?v=xxx
    $(basename "$0") play video.mp4
    $(basename "$0") play -k my.key video.mp4
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
    name=$(yt-dlp --print title "$url" 2>/dev/null | sed 's/[\/\\:]/-/g' || echo "video")
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
                    -k|--key)  KEY_PATH="$2"; shift 2 ;;
                    -h|--help) usage ;;
                    -*)        die "Unknown option: $1" ;;
                    *)         break ;;
                esac
            done
            [[ -z "${1:-}" ]] && die "File is required"
            do_play "$1" "$KEY_PATH"
            ;;
        -h|--help|help) usage ;;
        *) die "Unknown command: $ACTION (use 'download' or 'play')" ;;
    esac
}

main "$@"
