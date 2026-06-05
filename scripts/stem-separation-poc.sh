#!/usr/bin/env bash
# Stem-separation proof-of-concept for AudioLens.
#
# Builds sevagh/demucs.cpp (pure C++17 + Eigen, with Apple's Accelerate as
# the BLAS backend on macOS — no Homebrew needed), pulls a pre-converted
# htdemucs 4-source ggml weights file from Hugging Face, and runs it on an
# audio file you point it at.
#
# Outputs: four WAV files (vocals / drums / bass / other) in ./out/<basename>/
# plus a wall-clock and "× realtime" report so we have concrete numbers to
# decide whether C++ inference is fast enough on Apple Silicon.
#
# Usage:
#   ./scripts/stem-separation-poc.sh path/to/your_song.wav
#
# Optional env:
#   POC_DIR=~/stems-poc   (where to place the workdir; defaults to ./.stems-poc)
#   THREADS=6             (parallel std::threads in the mt CLI; default 4)
#   OMP_THREADS=4         (BLAS/OpenMP threads per std::thread; default 4)

set -euo pipefail

# ----- args & paths -----
SONG="${1:-}"
if [[ -z "$SONG" || ! -f "$SONG" ]]; then
    echo "usage: $0 <input_audio_file>"
    exit 1
fi
SONG="$(cd "$(dirname "$SONG")" && pwd)/$(basename "$SONG")"

POC_DIR="${POC_DIR:-$(pwd)/.stems-poc}"
THREADS="${THREADS:-4}"
OMP_THREADS="${OMP_THREADS:-4}"

REPO_DIR="$POC_DIR/demucs.cpp"
BUILD_DIR="$REPO_DIR/build"
WEIGHTS_DIR="$POC_DIR/weights"
WEIGHTS_FILE="$WEIGHTS_DIR/ggml-model-htdemucs-4s-f16.bin"
WEIGHTS_URL="https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-4s-f16.bin"

OUT_BASE="$(cd "$(dirname "$0")"/.. && pwd)/out"
OUT_DIR="$OUT_BASE/$(basename "$SONG" | sed -E 's/\.[^.]+$//')"
mkdir -p "$OUT_DIR" "$POC_DIR" "$WEIGHTS_DIR"

# ----- prerequisites -----
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
need git
need cmake
need curl
need c++

echo "==> workdir: $POC_DIR"
echo "==> input:   $SONG"
echo "==> output:  $OUT_DIR"
echo

# ----- clone (idempotent) -----
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "==> cloning demucs.cpp + submodules (Eigen, libnyquist, googletest)…"
    git clone --recurse-submodules --depth 1 --shallow-submodules \
        https://github.com/sevagh/demucs.cpp "$REPO_DIR"
else
    echo "==> repo already cloned, skipping"
fi

# ----- build -----
# On macOS, CMake's find_package(BLAS) picks up Apple's Accelerate framework
# automatically — no OpenBLAS, no Homebrew. (On Linux it grabs OpenBLAS via apt.)
if [[ ! -x "$BUILD_DIR/demucs_mt.cpp.main" ]]; then
    echo "==> configuring + building (Release)…"
    mkdir -p "$BUILD_DIR"
    cmake -S "$REPO_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" \
        --target demucs_mt.cpp.main >/dev/null
else
    echo "==> binary already built, skipping"
fi

# ----- weights -----
if [[ ! -f "$WEIGHTS_FILE" || ! -s "$WEIGHTS_FILE" ]]; then
    echo "==> downloading htdemucs (4-source, fp16) weights — ~80 MB…"
    curl -L --progress-bar -o "$WEIGHTS_FILE" "$WEIGHTS_URL"
fi
# Sanity: the actual file is ~80 MB. If we got a few-byte HTML error page,
# bail clearly instead of feeding garbage to the inference.
SIZE_BYTES=$(stat -f%z "$WEIGHTS_FILE" 2>/dev/null || stat -c%s "$WEIGHTS_FILE")
if (( SIZE_BYTES < 50000000 )); then
    echo "weights file looks too small ($SIZE_BYTES bytes) — download failed?"
    echo "try downloading manually from:"
    echo "  $WEIGHTS_URL"
    exit 1
fi
echo "==> weights OK ($(( SIZE_BYTES / 1024 / 1024 )) MB)"
echo

# ----- inference -----
# Song duration in seconds (best-effort; needs afinfo on macOS, or sox/ffprobe).
SONG_SECONDS=""
if command -v afinfo >/dev/null 2>&1; then
    SONG_SECONDS=$(afinfo "$SONG" 2>/dev/null \
        | awk -F': ' '/estimated duration/ {print $2}' \
        | awk '{print int($1)}')
fi

echo "==> separating with demucs_mt (threads=$THREADS, OMP=$OMP_THREADS)…"
START=$(date +%s)
OMP_NUM_THREADS="$OMP_THREADS" "$BUILD_DIR/demucs_mt.cpp.main" \
    "$WEIGHTS_FILE" "$SONG" "$OUT_DIR" "$THREADS"
END=$(date +%s)
ELAPSED=$(( END - START ))

echo
echo "==> done in ${ELAPSED}s"
if [[ -n "$SONG_SECONDS" && "$SONG_SECONDS" -gt 0 ]]; then
    # bash int division; for 1 decimal use awk
    RATIO=$(awk -v e="$ELAPSED" -v s="$SONG_SECONDS" 'BEGIN { printf "%.2f", e / s }')
    echo "==> song length: ${SONG_SECONDS}s  →  ${RATIO}× realtime"
fi

echo
echo "==> output files:"
ls -lh "$OUT_DIR"
