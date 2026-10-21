#!/usr/bin/env bash
# Music Generator Ubuntu installer. Add to repository root beside arch_linux.sh.
set -Eeuo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SOURCE_DIR/scripts/common.sh" ]]; then echo 'ERROR: Put ubuntu.sh in the music-generator repository root.' >&2; exit 1; fi
# shellcheck source=scripts/common.sh
source "$SOURCE_DIR/scripts/common.sh"
cd "$ROOT"
ACTION=install; BACKEND=auto; LM_SIZE=1.7B; XL=0; YES=0; DRY=0; REBUILD=0; BROWSER=1; CPU_FALLBACK=0
usage() { cat <<'HELP'
Music Generator Ubuntu installer
  ./ubuntu.sh [--install-only] [--yes] [--backend auto|cuda|cpu]
              [--lm 0.6B|1.7B|4B] [--xl] [--rebuild] [--cpu-fallback]
              [--dry-run] [--start|--stop|--status] [--no-browser] [--help]
--dry-run plans operations without installing, downloading, deleting or starting anything.
CUDA toolkit/driver must be installed separately (no automatic driver replacement).
HELP
}
while (($#)); do
 case "$1" in
  --yes|-y) YES=1;; --dry-run) DRY=1;; --install-only|--no-start) ACTION=install;;
  --start) ACTION=start;; --stop) ACTION=stop;; --status) ACTION=status;;
  --backend|--lm) [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }; if [[ $1 == --backend ]]; then BACKEND=$2; else LM_SIZE=$2; fi; shift;;
  --xl) XL=1;; --rebuild) REBUILD=1;; --cpu-fallback) CPU_FALLBACK=1;; --no-browser) BROWSER=0;;
  --help|-h) usage; exit 0;; *) echo "Unknown option: $1" >&2; usage; exit 2;;
 esac; shift
done
[[ $BACKEND == auto || $BACKEND == cuda || $BACKEND == cpu ]] || { echo "Invalid backend: $BACKEND" >&2; exit 2; }
[[ $LM_SIZE == 0.6B || $LM_SIZE == 1.7B || $LM_SIZE == 4B ]] || { echo "Invalid LM size: $LM_SIZE" >&2; exit 2; }
if [[ $ACTION != install ]]; then
 [[ $DRY == 0 ]] || { echo "DRY RUN: would delegate $ACTION to arch_linux.sh (no installation)."; exit 0; }
 opts=("--$ACTION"); [[ $BROWSER == 0 ]] && opts+=(--no-browser)
 # --start is safe after a completed install; otherwise it triggers the Arch installer.
 if [[ $ACTION == start && ( ! -x "$ENGINE/build/ace-server" || ! -f "$CONF" ) ]]; then echo 'Install with ./ubuntu.sh --install-only first.' >&2; exit 1; fi
 exec bash "$ROOT/arch_linux.sh" "${opts[@]}"
fi
[[ $(uname -s) == Linux ]] || { echo 'Linux required.' >&2; exit 1; }
# Permit Ubuntu and Ubuntu derivatives; reject Arch to prevent wrong package manager.
. /etc/os-release
[[ ${ID:-} == ubuntu || " ${ID_LIKE:-} " == *' ubuntu '* || " ${ID_LIKE:-} " == *' debian '* ]] || { echo "Ubuntu or Ubuntu-derived OS required: ${ID:-unknown}" >&2; exit 1; }
command -v apt-get >/dev/null || { echo 'apt-get is missing.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'This installer supports x86_64 only.' >&2; exit 1; }
# Prefer an explicit compiler, then the version selected by /usr/local/cuda,
# rather than Ubuntu's potentially outdated /usr/bin/nvcc. Do not change system alternatives.
select_cuda() {
 local candidate="${CUDACXX:-}" root version major minor
 if [[ -z $candidate && -x /usr/local/cuda/bin/nvcc ]]; then candidate=/usr/local/cuda/bin/nvcc; fi
 if [[ -z $candidate ]]; then candidate=$(command -v nvcc || true); fi
 [[ -n $candidate && -x $candidate ]] || return 1
 candidate=$(readlink -f "$candidate")
 root=$(cd "$(dirname "$candidate")/.." && pwd -P)
 version=$("$candidate" --version | sed -n 's/.*release \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p' | tail -1)
 [[ -n $version ]] || { echo "Cannot determine CUDA version: $candidate" >&2; return 1; }
 major=${version%%.*}; minor=${version#*.}
 # Blackwell / sm_120 requires a toolkit supporting compute capability 12.0.
 if [[ $major -lt 12 || ( $major -eq 12 && $minor -lt 8 ) ]]; then
  echo "CUDA $version at $candidate is too old for the supported Blackwell build (need CUDA >= 12.8)." >&2
  return 1
 fi
 [[ -x $root/bin/ptxas ]] || { echo "Missing ptxas in $root/bin" >&2; return 1; }
 export CUDA_HOME="$root" CUDA_PATH="$root" CUDAToolkit_ROOT="$root" CUDACXX="$candidate"
 export PATH="$root/bin:$PATH"
 echo "Selected CUDA $version: $CUDACXX (ptxas: $root/bin/ptxas)"
}
if [[ $BACKEND == auto ]]; then
 if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 && select_cuda; then BACKEND=cuda; else BACKEND=cpu; fi
fi
if [[ $BACKEND == cuda ]]; then
 command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 || { echo 'NVIDIA driver/GPU unavailable.' >&2; exit 1; }
 select_cuda || { echo 'Compatible CUDA toolkit missing. Use CUDA 12.8+ or --backend cpu.' >&2; exit 1; }
fi
LM_FILE="acestep-5Hz-lm-${LM_SIZE}-Q8_0.gguf"
echo "Music Generator Ubuntu setup | ${PRETTY_NAME:-$ID} | backend=$BACKEND | LM=$LM_SIZE"
packages=(build-essential cmake ninja-build git curl pkg-config libcurl4-openssl-dev lsof xdg-utils ca-certificates ccache)
if [[ $DRY == 1 ]]; then
 echo 'DRY RUN: no side effects.'
 printf 'PLAN apt-get install: '; printf '%s ' "${packages[@]}"; echo
 echo 'PLAN uv sync --locked'
 echo "PLAN git checkout $ACESTEP_REV and git submodule update --init --recursive"
 if [[ $BACKEND == cuda ]]; then echo "PLAN CUDA: $CUDACXX"; echo 'PLAN CMake: -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=native -DGGML_CPU_ALL_VARIANTS=OFF'; else echo 'PLAN CMake: -DGGML_CPU_ALL_VARIANTS=OFF'; fi
 echo "PLAN download + SHA256 verify: VAE, Qwen embedding, SFT, $LM_FILE $([[ $XL == 1 ]] && echo 'and XL' || true)"
 echo 'PLAN run local inference self-test and atomically write data/engine.conf'
 exit 0
fi
if [[ $YES != 1 ]]; then read -r -p 'Install Ubuntu dependencies and continue? [Y/n] ' ans; [[ $ans == '' || $ans == [Yy]* ]] || exit 1; fi
sudo apt-get update
sudo apt-get install -y "${packages[@]}"
if ! command -v uv >/dev/null 2>&1; then
 echo 'Installing uv via official Astral installer (https://astral.sh/uv/install.sh).'
 uv_installer=$(mktemp)
 curl -fsSL --retry 3 https://astral.sh/uv/install.sh -o "$uv_installer"
 sh "$uv_installer"
 rm -f "$uv_installer"
 export PATH="$HOME/.local/bin:$PATH"
 command -v uv >/dev/null 2>&1 || { echo 'uv installation failed.' >&2; exit 1; }
fi
uv sync --locked
mkdir -p "$ROOT/engine" "$DATA"
if [[ ! -d "$ENGINE/.git" ]]; then
 [[ ! -e "$ENGINE" ]] || { echo "Engine directory exists but is not a git clone: $ENGINE" >&2; exit 1; }
 git clone "$ACESTEP_REPO" "$ENGINE"
fi
( cd "$ENGINE"; git cat-file -e "$ACESTEP_REV^{commit}" 2>/dev/null || git fetch origin; git checkout --detach "$ACESTEP_REV"; git submodule update --init --recursive )
BUILD=0
[[ $REBUILD == 1 || ! -x "$ENGINE/build/ace-server" ]] && BUILD=1
# Never reuse a previous CPU build when CUDA was selected (or vice versa).
if [[ -f "$ENGINE/build/CMakeCache.txt" ]]; then
 if [[ $BACKEND == cuda ]]; then
  if ! grep -qx "GGML_CUDA:BOOL=ON" "$ENGINE/build/CMakeCache.txt"; then BUILD=1; fi
  cached_compiler=$(sed -n 's/^CMAKE_CUDA_COMPILER:FILEPATH=//p; s/^CMAKE_CUDA_COMPILER:STRING=//p' "$ENGINE/build/CMakeCache.txt" | head -n 1)
  [[ -n $cached_compiler && $(readlink -f "$cached_compiler") == "$CUDACXX" ]] || BUILD=1
 fi
 if [[ $BACKEND == cpu ]] && grep -qx "GGML_CUDA:BOOL=ON" "$ENGINE/build/CMakeCache.txt"; then BUILD=1; fi
else BUILD=1; fi
if [[ $BUILD == 1 ]]; then
 flags=(-DCMAKE_BUILD_TYPE=Release -DGGML_CPU_ALL_VARIANTS=OFF)
 if [[ $BACKEND == cuda ]]; then flags+=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=native); fi
 build_engine() {
  local target=$1; local -a f=(-DCMAKE_BUILD_TYPE=Release -DGGML_CPU_ALL_VARIANTS=OFF)
  if [[ $target == cuda ]]; then f+=(-DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER="$CUDACXX" -DCUDAToolkit_ROOT="$CUDA_HOME" -DCMAKE_CUDA_ARCHITECTURES=native); fi
  ( cd "$ENGINE"; rm -rf build; cmake -S . -B build "${f[@]}"; cmake --build build --config Release -j "${BUILD_JOBS:-4}" ) > "$DATA/build.log" 2>&1
 }
 if ! build_engine "$BACKEND"; then
  if [[ $BACKEND == cuda && $CPU_FALLBACK == 1 ]]; then echo 'CUDA build failed; explicit CPU fallback requested.'; BACKEND=cpu; build_engine cpu || { echo 'CPU build failed: data/build.log' >&2; exit 1; }
  else echo 'Build failed: data/build.log (no silent CUDA-to-CPU fallback).' >&2; exit 1; fi
 fi
fi
[[ -x "$ENGINE/build/ace-server" ]] || { echo 'ace-server executable missing after build.' >&2; exit 1; }
