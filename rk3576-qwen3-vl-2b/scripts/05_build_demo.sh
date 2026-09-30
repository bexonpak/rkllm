#!/usr/bin/env bash
# ============================================================================
#  05  交叉编译板端 demo (aarch64)
#
#  产物: ${MM_DIR}/deploy/install/demo_Linux_aarch64/
#          demo / imgenc / audioenc / demo.jpg / lib/{librknnrt.so,librkllmrt.so}
#        ${OUTPUT_DIR}/demo_Linux_aarch64/   (汇总，直接 adb push)
# ============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

banner "05 交叉编译板端 demo"
require_linux

need_cmd cmake "sudo apt-get install -y cmake"

# --- 选编译器 ---------------------------------------------------------------
# 分两种情形：
#   宿主机 x86_64  -> 交叉编译，需要 aarch64 工具链
#   宿主机 aarch64  -> 原生编译，板子本身就是 aarch64，直接用 gcc/g++ 即可
#                      （在 arm64 Linux / Docker Desktop 的 arm64 容器里就是这样）
HOST_ARCH="$(uname -m)"
NATIVE_ARM=0
CCXX=""; CCC=""
if [[ "${HOST_ARCH}" == "aarch64" || "${HOST_ARCH}" == "arm64" ]]; then
    NATIVE_ARM=1
    CCXX="$(command -v g++ || true)"
    CCC="$(command -v gcc || true)"
    [[ -n "${CCXX}" && -n "${CCC}" ]] || die "宿主机是 aarch64 但找不到 gcc/g++：apt-get install -y build-essential"
    c_ok "宿主机是 aarch64，采用原生编译（不需要交叉工具链）"
elif [[ -x "${GCC_COMPILER}/bin/aarch64-none-linux-gnu-g++" ]]; then
    CCXX="${GCC_COMPILER}/bin/aarch64-none-linux-gnu-g++"
    CCC="${GCC_COMPILER}/bin/aarch64-none-linux-gnu-gcc"
    c_ok "使用 Rockchip 官方工具链: ${GCC_COMPILER}"
elif command -v aarch64-linux-gnu-g++ >/dev/null 2>&1; then
    CCXX="$(command -v aarch64-linux-gnu-g++)"
    CCC="$(command -v aarch64-linux-gnu-gcc)"
    c_ok "使用 apt 交叉工具链: ${CCXX}"
    c_info "（推荐换官方工具链以获得更好的 aarch64 代码生成，但 apt 版也能编过）"
else
    die "找不到 aarch64 交叉编译器。二选一：
    A) 官方工具链（推荐）:
       wget https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu-a/10.2-2020.11/binrel/gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu.tar.xz
       mkdir -p ~/opts && tar -xf gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu.tar.xz -C ~/opts
    B) apt 工具链:
       sudo apt-get install -y g++-aarch64-linux-gnu gcc-aarch64-linux-gnu"
fi

# --- 编译 ------------------------------------------------------------------
DEPLOY_DIR="${MM_DIR}/deploy"
BUILD_DIR="${DEPLOY_DIR}/build-rk3576"

cd "${DEPLOY_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# 原生 aarch64 编译时不能设 CMAKE_SYSTEM_NAME（那会进入交叉编译模式，
# 反而找不到 OpenCV/OpenMP）；交给 CMake 按宿主机自己判定即可。
CMAKE_CROSS_ARGS=()
if (( NATIVE_ARM == 0 )); then
    CMAKE_CROSS_ARGS=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64)
fi

c_info "cmake 配置 ... (native_arm=${NATIVE_ARM})"
cmake .. \
    -DCMAKE_CXX_COMPILER="${CCXX}" \
    -DCMAKE_C_COMPILER="${CCC}" \
    -DCMAKE_BUILD_TYPE=Release \
    ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"} \
    || die "cmake 配置失败（OpenCV/OpenMP 找不到时见 README 排错章节）"

c_info "make -j$(nproc) ..."
make -j"$(nproc)" || die "编译失败"
make install  || die "make install 失败"

INSTALL_DIR="${DEPLOY_DIR}/install/demo_Linux_aarch64"
[[ -x "${INSTALL_DIR}/demo" ]] || die "没有生成 ${INSTALL_DIR}/demo"

# --- OpenMP 运行库（板子上常见缺 libgomp.so.1 / libomp.so.1） -----------------
# 注意：GCC 目录下的 "libgomp.so" 往往是链接脚本而不是 ELF，绝不能拷过去，
#       所以这里只认 libgomp.so.1 / libgomp.so.1.*，并且固定按 SONAME 命名。
ROCKCHIP_SYSROOT="$(dirname "$(dirname "${CCXX}")")/aarch64-none-linux-gnu/lib64"
SEARCH_DIRS=()
[[ -d "${ROCKCHIP_SYSROOT}" ]] && SEARCH_DIRS+=("${ROCKCHIP_SYSROOT}")
[[ -d /usr/lib/gcc-cross/aarch64-linux-gnu ]] && SEARCH_DIRS+=("/usr/lib/gcc-cross/aarch64-linux-gnu")
[[ -d /usr/aarch64-linux-gnu ]] && SEARCH_DIRS+=("/usr/aarch64-linux-gnu")
# 原生 aarch64（arm64 宿主机 / arm64 容器）的库路径
[[ -d /usr/lib/aarch64-linux-gnu ]] && SEARCH_DIRS+=("/usr/lib/aarch64-linux-gnu")
[[ -d /usr/lib/gcc/aarch64-linux-gnu ]] && SEARCH_DIRS+=("/usr/lib/gcc/aarch64-linux-gnu")
[[ -d /lib/aarch64-linux-gnu ]] && SEARCH_DIRS+=("/lib/aarch64-linux-gnu")

copy_openmp_lib() {
    # $1 = 需要的 SONAME，例如 libgomp.so.1
    local soname="$1" d src
    [[ ${#SEARCH_DIRS[@]} -eq 0 ]] && return 0
    for d in "${SEARCH_DIRS[@]}"; do
        # 精确优先，其次带小版本号
        for pat in "${soname}" "${soname}.*"; do
            src="$(find "${d}" -maxdepth 3 -name "${pat}" -type f 2>/dev/null | head -1)"
            if [[ -n "${src}" ]]; then
                cp -fL "${src}" "${INSTALL_DIR}/lib/${soname}" && \
                    c_info "附带 $(basename "${src}") -> lib/${soname}"
                return 0
            fi
        done
    done
    c_warn "没找到 ${soname}；若板端报 'cannot open shared object file'，请在板子上 apt install libgomp1"
    return 0
}

copy_openmp_lib "libgomp.so.1"
copy_openmp_lib "libomp.so.1"


# --- 汇总 ------------------------------------------------------------------
ensure_dir "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/demo_Linux_aarch64"
cp -a "${INSTALL_DIR}" "${OUTPUT_DIR}/"
# 把板端运行脚本放到 demo_Linux_aarch64 的**同级**目录：
# run_demo.sh 里是 APP_DIR/demo_Linux_aarch64 的假设，模型也放在 APP_DIR 下
cp -f "${KIT_DIR}/board/run_demo.sh" "${OUTPUT_DIR}/run_demo.sh"
chmod +x "${OUTPUT_DIR}/run_demo.sh"
c_ok "板端包: ${OUTPUT_DIR}/demo_Linux_aarch64 （+ run_demo.sh）"
ls -lh "${OUTPUT_DIR}/demo_Linux_aarch64" | sed 's/^/    /'
ls -lh "${OUTPUT_DIR}/demo_Linux_aarch64/lib" | sed 's/^/    /'

# --- 目标架构自检 ----------------------------------------------------------
if command -v file >/dev/null 2>&1; then
    f="$(file -b "${OUTPUT_DIR}/demo_Linux_aarch64/demo")"
    c_info "demo 架构: ${f}"
    [[ "${f}" == *aarch64* || "${f}" == *ARM* ]] || c_warn "demo 看起来不是 aarch64，交叉编译配置可能没生效"
fi

echo
c_info "下一步:  bash scripts/06_push_to_board.sh"
