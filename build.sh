#!/bin/bash
# Android 12-5.10 Kernel Build Script
set -euo pipefail

# --- Configuration ---------------------------------------------------------
readonly LLVM_VERSION="23.1.0-rc3"
readonly LLVM_ARCH="x86_64"
readonly LLVM_MAJOR="${LLVM_VERSION%%.*}"
readonly TOOLCHAIN_ROOT="$HOME/kernel/toolchain"
readonly CLANG_URL="https://mirrors.edge.kernel.org/pub/tools/llvm/files/llvm-${LLVM_VERSION}-${LLVM_ARCH}.tar.xz"
readonly CLANG_HOME="$TOOLCHAIN_ROOT/clang-${LLVM_MAJOR}"
readonly OUT_DIR="out"
readonly TARGET_ARCH="arm64"
readonly LOCAL_VERSION="-Rama982-RE/r26-noSU"
readonly TIMEZONE="Asia/Jakarta"
rc=0  # Di-set oleh EXIT trap saat failure, dibaca dari trap itu juga.

# --- Logging ---------------------------------------------------------------
log_info() { printf '\033[0;32m[INFO]\033[0m %s\n' "$1"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
log_err()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2; }

# --- Toolchain -------------------------------------------------------------
# Args: name url dest marker
fetch_toolchain() {
    local n=$1 u=$2 d=$3 m=$4
    [[ -n "$m" && -e "$d/$m" ]] && { log_info "Toolchain $n sudah siap."; return 0; }

    log_info "Mengunduh toolchain $n..."
    mkdir -p "$d"

    local t; t=$(mktemp) || { log_err "Gagal mktemp."; return 1; }

    # Per-tool argv: cells of `cmd` become distinct argv entries via "${cmd[@]}".
    # curl butuh "-o FILE" setelah URL; wget butuh "-qO FILE" sebelum URL.
    local -a cmd
    if   command -v curl >/dev/null; then cmd=(curl -fL "$u" -o "$t")
    elif command -v wget >/dev/null; then cmd=(wget -qO "$t" "$u")
    else rm -f "$t"; log_err "curl atau wget tidak ditemukan."; return 1; fi

    if ! "${cmd[@]}"; then
        rm -f "$t"; log_err "Gagal mengunduh $u."; return 1
    fi
    log_info "Mengekstrak..."
    if ! tar -xJf "$t" -C "$d" --strip-components=1; then
        rm -f "$t"; log_err "Gagal mengekstrak."; return 1
    fi
    rm -f "$t"
}

# --- Kernel Build Steps ----------------------------------------------------
setup_environment() {
    export PATH="$CLANG_HOME/bin:$PATH" LLVM=1 LLVM_IAS=1 \
           ARCH="$TARGET_ARCH" LOCALVERSION="$LOCAL_VERSION" LTO=thin \
           TZ="$TIMEZONE"
}

configure_kernel() {
    log_info "Menyiapkan konfigurasi kernel..."
    mkdir -p "$OUT_DIR"
    printf '%s' "-g$(git rev-parse --short HEAD 2>/dev/null || true)" > .scmversion
    make O="$OUT_DIR" gki_defconfig
    scripts/config --file "$OUT_DIR/.config" \
        -e LTO_CLANG -e LTO_CLANG_THIN -d LTO_NONE -d LTO_CLANG_FULL
    make O="$OUT_DIR" olddefconfig savedefconfig
}

build_kernel() {
    log_info "Memulai kompilasi kernel (Image)..."
    make -j"$(nproc --all)" O="$OUT_DIR" Image
}

print_kernel_version() {
    local f=$OUT_DIR/include/generated/utsrelease.h
    [[ -f "$f" ]] || { log_warn "utsrelease.h tidak ditemukan."; return; }
    local v
    v=$(awk -F'"' '/^#define[[:space:]]+UTS_RELEASE[[:space:]]+/{print $2; exit}' "$f")
    [[ -n "$v" ]] && log_info "Versi Kernel target: $v"
}

verify_kmi() {
    log_info "Menjalankan verifikasi KMI..."
    [[ -f KMI_function_symbols_test.py ]] || {
        log_warn "KMI_function_symbols_test.py tidak ditemukan. Verifikasi dilewati."
        return
    }
    python3 KMI_function_symbols_test.py android/abi_gki_aarch64.xml "$OUT_DIR/vmlinux.symvers"
}

# --- Main ------------------------------------------------------------------
main() {
    local t0=$SECONDS
    trap 'rc=$?; if (( rc )); then log_err "Build gagal (exit=$rc) setelah $((SECONDS/60))m $((SECONDS%60))s"; fi' EXIT

    fetch_toolchain "clang-$LLVM_MAJOR" "$CLANG_URL" "$CLANG_HOME" bin/clang
    setup_environment
    configure_kernel
    build_kernel

    log_info "Kompilasi selesai dalam $(((SECONDS-t0)/60))m $(((SECONDS-t0)%60))s"
    print_kernel_version
    verify_kmi

    trap - EXIT
    log_info "Proses build secara keseluruhan selesai dengan sukses!"
}

main "$@"
