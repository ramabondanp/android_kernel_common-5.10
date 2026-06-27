#!/bin/bash
# Android 12-5.10 Kernel Build Script
set -euo pipefail

# ==========================================
# Konfigurasi Utama
# ==========================================
readonly LLVM_VERSION="22.1.8"
readonly LLVM_ARCH="x86_64"
readonly LLVM_MAJOR="${LLVM_VERSION%%.*}"
readonly TOOLCHAIN_ROOT="$HOME/kernel/toolchain"
readonly CLANG_URL="https://mirrors.edge.kernel.org/pub/tools/llvm/files/llvm-${LLVM_VERSION}-${LLVM_ARCH}.tar.xz"
readonly CLANG_HOME="$TOOLCHAIN_ROOT/clang-${LLVM_MAJOR}"

readonly OUT_DIR="out"
readonly TARGET_ARCH="arm64"
readonly LOCAL_VERSION="-Rama982-RE/r23-noSU"

# ==========================================
# Helper Logging
# ==========================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ==========================================
# Fungsi-fungsi Utilitas & Build
# ==========================================

download_and_extract() {
    local name="$1" url="$2" dest="$3" marker="$4"

    if [[ -n "$marker" && -e "$dest/$marker" ]]; then
        log_info "Toolchain $name sudah siap. Melewati unduhan."
        return 0
    fi

    log_info "Mengunduh toolchain $name..."
    mkdir -p "$dest"

    local tmp_file
    tmp_file=$(mktemp)

    # Pastikan file temporary terhapus meskipun ada error saat unduh
    trap 'rm -f "$tmp_file"' RETURN EXIT

    if command -v curl &>/dev/null; then
        curl -fL "$url" -o "$tmp_file"
    elif command -v wget &>/dev/null; then
        wget -qO "$tmp_file" "$url"
    else
        log_err "curl atau wget tidak ditemukan. Instal salah satunya terlebih dahulu."
        exit 1
    fi

    log_info "Mengekstrak toolchain $name..."
    tar -xJf "$tmp_file" -C "$dest" --strip-components=1

    # Bersihkan trap dan file secara manual setelah sukses
    trap - RETURN EXIT
    rm -f "$tmp_file"
}

setup_environment() {
    log_info "Mengatur variabel lingkungan (Environment Variables)..."
    export PATH="$CLANG_HOME/bin:$PATH"
    export LLVM=1
    export LLVM_IAS=1
    export ARCH="$TARGET_ARCH"
    export LOCALVERSION="$LOCAL_VERSION"

    # Opsi Thin LTO
    export LTO=thin
}

configure_kernel() {
    log_info "Menyiapkan konfigurasi Kernel (Kconfig)..."

    mkdir -p "$OUT_DIR"
    printf '%s' "-g$(git rev-parse --short HEAD 2>/dev/null || true)" > .scmversion

    make O="$OUT_DIR" gki_defconfig

    # Mengaktifkan Thin LTO via scripts/config
    scripts/config --file "$OUT_DIR/.config" \
        -e LTO_CLANG \
        -e LTO_CLANG_THIN \
        -d LTO_NONE \
        -d LTO_CLANG_FULL

    # Terapkan perubahan dependensi Kconfig yang baru dimodifikasi
    make O="$OUT_DIR" olddefconfig
    make O="$OUT_DIR" savedefconfig
}

build_kernel() {
    log_info "Memulai kompilasi kernel (Image)..."
    make -j"$(nproc --all)" O="$OUT_DIR" Image
}

print_kernel_version() {
    local utsrelease="$OUT_DIR/include/generated/utsrelease.h"
    if [[ -f "$utsrelease" ]]; then
        local uts
        uts=$(sed -n 's/^#define[[:space:]]\+UTS_RELEASE[[:space:]]\+"\(.*\)"/\1/p' "$utsrelease")
        [[ -n "$uts" ]] && log_info "Versi Kernel target: $uts"
    else
        log_warn "File utsrelease.h tidak ditemukan (proses build mungkin tidak tuntas)."
    fi
}

verify_kmi() {
    log_info "Menjalankan verifikasi KMI..."
    if [[ -f "KMI_function_symbols_test.py" ]]; then
        python3 KMI_function_symbols_test.py android/abi_gki_aarch64.xml "$OUT_DIR"/vmlinux.symvers
    else
        log_warn "KMI_function_symbols_test.py tidak ditemukan di direktori saat ini. Verifikasi dilewati."
    fi
}

# ==========================================
# Alur Eksekusi Utama (Main)
# ==========================================
main() {
    local start_time=$SECONDS

    # Trap global untuk menangani kegagalan build
    trap 'rc=$?; if (( rc != 0 )); then log_err "Build gagal (exit code=$rc) setelah $((SECONDS/60))m $((SECONDS%60))s"; fi' EXIT

    download_and_extract "clang-${LLVM_MAJOR}" "$CLANG_URL" "$CLANG_HOME" "bin/clang"
    setup_environment
    configure_kernel
    build_kernel

    local total_time=$((SECONDS - start_time))
    log_info "Kompilasi selesai dalam waktu: $((total_time / 60))m $((total_time % 60))s"

    print_kernel_version
    verify_kmi

    # Hapus trap karena skrip berhasil mencapai akhir
    trap - EXIT
    log_info "Proses build secara keseluruhan selesai dengan sukses!"
}

# Jalankan skrip
main "$@"
