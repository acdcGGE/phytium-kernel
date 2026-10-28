#!/usr/bin/env bash
#===============================================================================
# build-phytium-kernel-deb.sh
#
# 功能：从 Gitee 拉取 phytium_embedded/phytium-linux-kernel 最新源码，
#       编译内核并打包为 Debian 安装包（linux-image-*.deb / linux-headers-*.deb）。
#
# 用法示例：
#   ./build-phytium-kernel-deb.sh                  # 默认：最新默认分支 -> arm64 -> 自动选 defconfig
#   ./build-phytium-kernel-deb.sh --install-deps   # 先自动安装编译依赖（需要 sudo）
#   ./build-phytium-kernel-deb.sh -r v6.6.63       # 指定 tag / 分支 / commit
#   ./build-phytium-kernel-deb.sh --full-pkg       # 额外产出 linux-source / linux-libc-dev 包
#   ./build-phytium-kernel-deb.sh --dry-run        # 只检查环境并打印计划，不编译
#
# 说明：
#   * 内核编译较慢（通常 30 分钟 ~ 2 小时以上），且需要 20GB+ 磁盘空间。
#   * deb 打包使用 fakeroot，不需要 root；只有 --install-deps 安装依赖时才需要 sudo。
#   * 产物默认输出到 ~/phytium-kernel-build/debs/ 。
#===============================================================================
set -Eeuo pipefail

#-------------------------------------------------------------------------------
# 默认参数（均可用命令行参数或同名环境变量覆盖）
#-------------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://gitee.com/phytium_embedded/phytium-linux-kernel.git}"
WORK_DIR="${WORK_DIR:-$HOME/phytium-kernel-build}"
SRC_DIR="${SRC_DIR:-}"
OUT_DIR="${OUT_DIR:-}"
REF="${REF:-}"                       # 空 = 默认分支最新；可填 tag / 分支 / commit
DEPTH="${DEPTH:-1}"                  # git clone 深度；0 = 完整历史
PULL="${PULL:-1}"                    # 1 = 源码目录已存在则 fetch 更新
ARCH="${ARCH:-arm64}"
DEFCONFIG="${DEFCONFIG:-}"           # 空 = 自动挑选 phytium 专用配置，否则用 defconfig
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
LOCALVERSION="${LOCALVERSION:-}"     # 追加到内核版本号（可空）
PKG_REVISION="${PKG_REVISION:-1}"    # deb 包修订号
INSTALL_DEPS="${INSTALL_DEPS:-0}"    # 1 = 自动安装依赖
DRY_RUN="${DRY_RUN:-0}"
TARGET="${TARGET:-bindeb-pkg}"       # bindeb-pkg（仅 image+headers）或 deb-pkg（含 source/libc-dev）
FRAGMENTS=()                         # 额外配置片段，可多次 --fragment 指定
WITH_HEADERS="${WITH_HEADERS:-0}"    # 1 = 强制开启 CONFIG_MODULES，确保产出 linux-headers
CLEAN="${CLEAN:-0}"                  # 1 = 配置前 make mrproper 清理旧构建

# 归一化路径
[ -n "$SRC_DIR" ] || SRC_DIR="$WORK_DIR/src"
[ -n "$OUT_DIR" ] || OUT_DIR="$WORK_DIR/debs"

#-------------------------------------------------------------------------------
# 基础输出函数
#-------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'
    C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""
fi

log()  { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_ERR"  "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
build-phytium-kernel-deb.sh — 拉取 phytium 内核源码、编译并打包为 .deb

用法:
  ./build-phytium-kernel-deb.sh [选项]

选项:
  -r, --ref REF        指定 tag / 分支 / commit（默认取默认分支最新）
  -d, --defconfig NAME 指定配置：完整 *_defconfig；若给 *.config 片段则叠加到基础 defconfig
  -j, --jobs N         并行编译路数（默认 nproc）
  -w, --work DIR       工作目录（默认 ~/phytium-kernel-build）
  -o, --out DIR        产物目录（默认 <work>/debs）
  -l, --localver STR   追加内核本地版本号
      --fragment FILE  追加配置片段（可多次，叠加到基础配置，如 phytium_debug.config）
      --with-headers   强制开启 CONFIG_MODULES，确保产出 linux-headers 包
      --clean          配置前执行 make mrproper 清理旧构建
      --install-deps   自动安装编译依赖（需要 sudo）
      --full-pkg       同时产出 linux-source / linux-libc-dev 包
      --no-pull        已存在源码时不拉取更新
      --deep           完整克隆历史（默认浅克隆 depth=1）
      --dry-run        只检查环境并打印计划，不编译
  -h, --help           显示本帮助

示例:
  ./build-phytium-kernel-deb.sh --install-deps
  ./build-phytium-kernel-deb.sh -r v6.6.63 -j 8
EOF
}

#-------------------------------------------------------------------------------
# 参数解析
#-------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -r|--ref)        REF="$2"; shift 2 ;;
            -d|--defconfig)  DEFCONFIG="$2"; shift 2 ;;
            -j|--jobs)       JOBS="$2"; shift 2 ;;
            -o|--out)        OUT_DIR="$2"; shift 2 ;;
            -w|--work)       WORK_DIR="$2"; SRC_DIR="$WORK_DIR/src"; OUT_DIR="$WORK_DIR/debs"; shift 2 ;;
            --install-deps)  INSTALL_DEPS=1; shift ;;
            --full-pkg)      TARGET="deb-pkg"; shift ;;
            --fragment)      FRAGMENTS+=("$2"); shift 2 ;;
            --with-headers)  WITH_HEADERS=1; shift ;;
            --clean)         CLEAN=1; shift ;;
            --no-pull)       PULL=0; shift ;;
            --deep)          DEPTH=0; shift ;;
            -l|--localver)   LOCALVERSION="$2"; shift 2 ;;
            --dry-run)       DRY_RUN=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "未知参数: $1 （用 --help 查看用法）" ;;
        esac
    done
    case "$JOBS" in ''|*[!0-9]*) die "无效的 jobs 数: $JOBS" ;; esac
}

#-------------------------------------------------------------------------------
# 交叉编译前缀探测
#-------------------------------------------------------------------------------
detect_cross() {
    CROSS_COMPILE=""
    local host_arch; host_arch="$(uname -m)"
    case "$ARCH" in
        arm64) [ "$host_arch" != "aarch64" ] && CROSS_COMPILE="aarch64-linux-gnu-" ;;
        arm)   [ "$host_arch" != "armv7l"  ] && CROSS_COMPILE="arm-linux-gnueabihf-" ;;
    esac
    [ -z "$CROSS_COMPILE" ] || log "检测到交叉编译：CROSS_COMPILE=$CROSS_COMPILE"
}

#-------------------------------------------------------------------------------
# 依赖检查 / 安装
#-------------------------------------------------------------------------------
APT_DEPS=(git build-essential bc bison flex libssl-dev libelf-dev
          libncurses-dev libncursesw5-dev cpio rsync dwarves zstd lz4
          xz-utils fakeroot dpkg-dev debhelper ca-certificates)

check_deps_report() {
    local missing=() c
    for c in git make gcc ld bc bison flex cpio rsync dpkg-deb fakeroot; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    # 交叉编译工具链
    if [ -n "${CROSS_COMPILE:-}" ] && ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        missing+=("${CROSS_COMPILE}gcc")
    fi
    if [ ${#missing[@]} -eq 0 ]; then
        ok "编译依赖检查通过"
        return 0
    fi
    warn "缺少以下命令: ${missing[*]}"
    warn "建议执行：  sudo apt-get update && sudo apt-get install -y ${APT_DEPS[*]}"
    return 1
}

install_deps() {
    log "开始安装编译依赖（需要 sudo 密码）..."
    local pkgs=("${APT_DEPS[@]}")
    if [ -n "${CROSS_COMPILE:-}" ]; then
        case "$ARCH" in
            arm64) pkgs+=(gcc-aarch64-linux-gnu) ;;
            arm)   pkgs+=(gcc-arm-linux-gnueabihf) ;;
        esac
    fi
    sudo apt-get update
    sudo apt-get install -y "${pkgs[@]}"
    hash -r
    ok "依赖安装完成"
}

#-------------------------------------------------------------------------------
# 磁盘空间检查（至少 20GB 可用）
#-------------------------------------------------------------------------------
check_disk() {
    mkdir -p "$WORK_DIR"
    local avail_kb avail_gb
    avail_kb=$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}')
    avail_gb=$((avail_kb / 1024 / 1024))
    if [ "$avail_gb" -lt 20 ]; then
        warn "磁盘可用约 ${avail_gb}GB，低于建议的 20GB，编译可能中途失败"
    else
        ok "磁盘可用约 ${avail_gb}GB，满足需求"
    fi
}

#-------------------------------------------------------------------------------
# 同步源码
#-------------------------------------------------------------------------------
sync_source() {
    mkdir -p "$WORK_DIR"
    if [ -d "$SRC_DIR/.git" ]; then
        if [ "$PULL" = "1" ]; then
            log "源码目录已存在，拉取最新更新 ..."
            git -C "$SRC_DIR" fetch --tags --prune origin
            if [ -n "$REF" ]; then
                git -C "$SRC_DIR" checkout "$REF"
            else
                local defbr
                defbr=$(git -C "$SRC_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
                        | sed 's@^origin/@@' || true)
                [ -n "$defbr" ] || defbr=$(git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD)
                git -C "$SRC_DIR" checkout "$defbr"
                git -C "$SRC_DIR" pull --ff-only origin "$defbr"
            fi
        else
            log "跳过更新（--no-pull），沿用现有源码"
        fi
    else
        log "克隆源码：$REPO_URL"
        if [ "$DEPTH" -gt 0 ]; then
            if [ -n "$REF" ]; then
                git clone --depth "$DEPTH" --branch "$REF" "$REPO_URL" "$SRC_DIR"
            else
                git clone --depth "$DEPTH" "$REPO_URL" "$SRC_DIR"
            fi
        else
            git clone "$REPO_URL" "$SRC_DIR"
            if [ -n "$REF" ]; then
                git -C "$SRC_DIR" checkout "$REF"
            fi
        fi
    fi
    ok "源码就绪：$(git -C "$SRC_DIR" rev-parse --short HEAD) $(git -C "$SRC_DIR" log -1 --format='%s')"
}

#-------------------------------------------------------------------------------
# 挑选 defconfig
#-------------------------------------------------------------------------------
detect_defconfig() {
    local d
    # 优先完整的 phytium_defconfig；否则任意 *_defconfig。
    # 绝不选 *.config —— 那是需要叠加到基础配置上的片段(overlay)。
    if [ -f "$SRC_DIR/arch/$ARCH/configs/phytium_defconfig" ]; then
        printf 'phytium_defconfig'
        return 0
    fi
    d=$(ls "$SRC_DIR/arch/$ARCH/configs/" 2>/dev/null | grep -E '_defconfig$' | head -n1 || true)
    if [ -n "$d" ]; then
        printf '%s' "$d"
    else
        printf 'defconfig'
    fi
}

#-------------------------------------------------------------------------------
# 配置内核
#-------------------------------------------------------------------------------
configure_kernel() {
    cd "$SRC_DIR"

    if [ "$CLEAN" = "1" ]; then
        log "清理旧构建（make mrproper）..."
        make ARCH="$ARCH" CROSS_COMPILE="${CROSS_COMPILE:-}" mrproper || true
    fi

    [ -n "$DEFCONFIG" ] || DEFCONFIG="$(detect_defconfig)"

    # 组装：基础配置 + 片段(overlay)
    local base="$DEFCONFIG"
    local frags=()
    # 若 -d 给的是 *.config，说明它是片段，叠加到自动探测的完整 defconfig 上
    if [[ "$base" == *.config ]]; then
        if [ -f "arch/$ARCH/configs/$base" ]; then
            frags+=("arch/$ARCH/configs/$base")
        elif [ -f "$base" ]; then
            frags+=("$base")
        else
            die "找不到配置片段：$base"
        fi
        base="$(detect_defconfig)"
    fi
    # 追加 --fragment 指定的片段
    if [ ${#FRAGMENTS[@]} -gt 0 ]; then
        local f
        for f in "${FRAGMENTS[@]}"; do
            if [ -f "arch/$ARCH/configs/$f" ]; then
                frags+=("arch/$ARCH/configs/$f")
            elif [ -f "$f" ]; then
                frags+=("$f")
            else
                die "找不到配置片段：$f"
            fi
        done
    fi

    log "基础配置：$base (ARCH=$ARCH)"
    [ -f "arch/$ARCH/configs/$base" ] || die "找不到基础配置 arch/$ARCH/configs/$base"
    make ARCH="$ARCH" CROSS_COMPILE="${CROSS_COMPILE:-}" "$base"

    # 叠加片段（如 phytium_debug.config：仅 22 行的 overlay，必须叠在完整 defconfig 之上）
    if [ ${#frags[@]} -gt 0 ]; then
        log "合并配置片段：${frags[*]}"
        scripts/kconfig/merge_config.sh -m .config "${frags[@]}"
    fi

    # 规避常见构建失败：关闭模块签名、清空不存在的证书路径、缺少 pahole 时关掉 BTF
    ./scripts/config --file .config --disable MODULE_SIG   || true
    ./scripts/config --file .config --disable MODULE_SIG_ALL || true
    ./scripts/config --file .config --disable MODULE_SIG_FORCE || true
    ./scripts/config --file .config --set-str SYSTEM_TRUSTED_KEYS "" || true
    ./scripts/config --file .config --set-str SYSTEM_REVOCATION_KEYS "" || true
    if [ -n "$LOCALVERSION" ]; then
        ./scripts/config --file .config --set-str LOCALVERSION "$LOCALVERSION"
    fi
    if ! command -v pahole >/dev/null 2>&1; then
        warn "未安装 pahole(dwarves)，将关闭 CONFIG_DEBUG_INFO_BTF"
        ./scripts/config --file .config --disable DEBUG_INFO_BTF || true
    fi
    # 需要 headers 包时，必须开启可加载模块支持（mkdebian 以 CONFIG_MODULES=y 为条件生成该包）
    if [ "$WITH_HEADERS" = "1" ]; then
        ./scripts/config --file .config --enable MODULES
    fi

    make ARCH="$ARCH" CROSS_COMPILE="${CROSS_COMPILE:-}" olddefconfig
    # 确保 include/config/auto.conf 与 .config 同步：
    # mkdebian 的 is_enabled 读取的是 auto.conf，未同步会导致 headers 包被误判跳过。
    make ARCH="$ARCH" CROSS_COMPILE="${CROSS_COMPILE:-}" syncconfig >/dev/null 2>&1 || true

    if grep -q '^CONFIG_MODULES=y' .config; then
        ok "配置完成（CONFIG_MODULES=y → 会产出 linux-headers 包）"
    else
        warn "配置完成，但 CONFIG_MODULES 未开启 —— 打包不会生成 linux-headers 包"
        warn "需要 headers 请加 --with-headers，或选用带 CONFIG_MODULES=y 的完整 defconfig"
    fi
}

#-------------------------------------------------------------------------------
# 编译 + 打包 deb
#-------------------------------------------------------------------------------
build_and_package() {
    cd "$SRC_DIR"
    local kver debver
    kver=$(make -s ARCH="$ARCH" CROSS_COMPILE="${CROSS_COMPILE:-}" kernelrelease)
    log "内核版本：$kver"
    # Debian 版本号中 upstream_version 不宜含 '-'，统一替换为 '.'
    debver=$(printf '%s' "$kver" | tr '-' '.')
    export KBUILD_DEBARCH; KBUILD_DEBARCH=$(dpkg --print-architecture)
    export KDEB_PKGVERSION="${debver}-${PKG_REVISION}"
    export DEB_BUILD_OPTIONS="parallel=$JOBS"

    log "开始编译（并行 $JOBS 路）..."
    make -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="${CROSS_COMPILE:-}"

    # bindeb-pkg 需要 debian/ 目录由 mkdebian 生成；若源码自带 debian/ 先临时移开
    local bak=""
    if [ -d debian ]; then
        bak="debian.bak.$$"
        warn "源码中存在 debian/ 目录，临时移开以便使用 mkdebian"
        mv debian "$bak"
    fi

    log "开始打包 .deb（目标：$TARGET）..."
    local rc=0
    make -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="${CROSS_COMPILE:-}" "$TARGET" || rc=$?

    # 无论成功与否都还原源码自带的 debian/ 目录
    if [ -n "$bak" ] && [ -d "$bak" ]; then
        rm -rf debian
        mv "$bak" debian
    fi
    [ "$rc" -eq 0 ] || die "打包失败（$TARGET），请查看构建日志"
}

#-------------------------------------------------------------------------------
# 收集产物
#-------------------------------------------------------------------------------
collect_debs() {
    mkdir -p "$OUT_DIR"
    local parent; parent="$(dirname "$SRC_DIR")"
    local marker="$WORK_DIR/.deb_stamp"
    local moved=0 f
    while IFS= read -r -d '' f; do
        mv -f "$f" "$OUT_DIR"/ && moved=$((moved+1))
    done < <(find "$parent" -maxdepth 1 -type f -name '*.deb' -newer "$marker" -print0 2>/dev/null)
    if [ "$moved" -eq 0 ]; then
        warn "未在 $parent 找到本次新生成的 .deb，请检查打包日志"
        return 0
    fi
    ok "已收集 $moved 个 deb 包到：$OUT_DIR"
}

#-------------------------------------------------------------------------------
# 打印计划（dry-run）
#-------------------------------------------------------------------------------
print_plan() {
    cat <<EOF
${C_BOLD}===== 构建计划 =====${C_RESET}
  仓库        : $REPO_URL
  引用(ref)   : ${REF:-<默认分支最新>}
  工作目录    : $WORK_DIR
  源码目录    : $SRC_DIR
  产物目录    : $OUT_DIR
  目标架构    : $ARCH  ${CROSS_COMPILE:+(CROSS_COMPILE=$CROSS_COMPILE)}
  内核配置    : ${DEFCONFIG:-<自动: phytium_defconfig>}
  配置片段    : ${FRAGMENTS[*]:-<无>}
  产出 headers: $([ "$WITH_HEADERS" = "1" ] && echo "强制开启 CONFIG_MODULES" || echo "按配置决定")
  并行度      : $JOBS
  打包目标    : $TARGET
  本地版本    : ${LOCALVERSION:-<无>}
  deb 修订号  : $PKG_REVISION
===================================
EOF
    log "预演结束。去掉 --dry-run 即可开始真实构建。"
}

#-------------------------------------------------------------------------------
# 主流程
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    detect_cross

    if [ "$DRY_RUN" = "1" ]; then
        log "== DRY RUN：仅检查环境 =="
        print_plan
        check_disk
        check_deps_report || true
        return 0
    fi

    if ! check_deps_report; then
        if [ "$INSTALL_DEPS" = "1" ]; then
            install_deps
        else
            die "缺少编译依赖。加 --install-deps 自动安装，或按上方提示手动安装。"
        fi
    fi

    check_disk

    local logfile="$WORK_DIR/build-$(date +%Y%m%d-%H%M%S).log"
    log "构建日志：$logfile"

    {
        sync_source
        configure_kernel
        touch "$WORK_DIR/.deb_stamp"
        build_and_package
        collect_debs
    } 2>&1 | tee -a "$logfile"

    # 简单汇总
    echo
    ok "构建流程结束"
    if compgen -G "$OUT_DIR/*.deb" >/dev/null; then
        log "生成的 deb 包："
        ls -lh "$OUT_DIR"/*.deb
        if ! compgen -G "$OUT_DIR/linux-headers-*.deb" >/dev/null; then
            warn "未生成 linux-headers 包：需 CONFIG_MODULES=y（本次配置为 n 时不会产出）"
            warn "解决：加 --with-headers，或使用带 CONFIG_MODULES=y 的完整 defconfig"
        fi
        log "安装示例： sudo dpkg -i $OUT_DIR/linux-image-*.deb"
    fi
}

main "$@"
