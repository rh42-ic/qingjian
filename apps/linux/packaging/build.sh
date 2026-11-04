#!/usr/bin/env bash
# 打 Linux 发行包：deb（Debian 13 / Ubuntu 25.04+）、rpm（Fedora 42+）、
# el8 / el9（RHEL 8/9 及 AlmaLinux、Rocky 等重建版，IBus-only）。
#
#   apps/linux/packaging/build.sh               两种都打（deb rpm）
#   apps/linux/packaging/build.sh deb rpm       只打给出的几种
#   apps/linux/packaging/build.sh el8           只打 RHEL 8 的 IBus-only rpm
#   apps/linux/packaging/build.sh el8 el9       两代 EL 都打
#   apps/linux/packaging/build.sh deb rpm el8 el9   全部都打
#   QINGJIAN_SAMPLE=1 apps/linux/packaging/build.sh   只带样例词库（没有产品数据时）
#
# 产物在 target/linux-pkg/out/（el8/el9 在各自的子目录）。全部在容器里编，只要 docker（免 sudo）：
# - Rust 的 Server 与 IBus 前端在 Ubuntu 22.04 里编一次（glibc 2.35），deb/rpm 共用，老一点的发行版也跑得起来；
# - EL8/EL9 不复用 Ubuntu 产物：glibc 太新，必须在各自的 AlmaLinux 容器里编（用宿主的 rustup 工具链）；
# - fcitx5 插件要对着目标发行版自己的 fcitx5 编（CMakeLists 要 5.1.8+），deb 在 Debian 13、rpm 在 Fedora 42 里编；
#   EL 没有 fcitx5，el8/el9 只出 IBus-only 的 qingjian 主包，不建 qingjian-fcitx5 子包。
# 每种包里 Server 与数据一个包、fcitx5 插件一个包（IBus 前端没有额外依赖，跟 Server 同包；EL 只有这一包）。
# 设计与限制见 docs/notes/linux-packaging.md；打完用 smoke/run.sh（deb/rpm）或 smoke/run-el.sh（EL）在干净容器里装一遍自检。
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
work="$root/target/linux-pkg"
out="$work/out"
formats=("$@")
((${#formats[@]})) || formats=(deb rpm)
for format in "${formats[@]}"; do
  case "$format" in deb|rpm|el8|el9) ;; *) echo "只认 deb / rpm / el8 / el9：$format" >&2; exit 2 ;; esac
done
command -v docker >/dev/null || { echo '要 docker' >&2; exit 1; }

# 版本：Server 的 Cargo.toml 是 0.1.0-dev 这种；开发版接上 git 短哈希，发行格式各有各的写法
cargo_version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/apps/linux/server/Cargo.toml" | head -1)
upstream=${cargo_version%%-*}
git_rev=$(git -C "$root" rev-parse --short HEAD)
if [[ "$cargo_version" == *-dev ]]; then
  deb_version="${upstream}~dev+git${git_rev}"   # ~ 排在正式版之前
  rpm_release="0.dev.git${git_rev}"
else
  deb_version="$upstream"
  rpm_release=1
fi
echo "==> 版本 $cargo_version（$git_rev）"
mkdir -p "$out"

# 镜像只装编译工具，按内容打标签，改了才重建
image() {
  local name=$1 dockerfile=$2 tag
  tag="qingjian-pkg-$name:$(printf '%s' "$dockerfile" | sha256sum | cut -c1-12)"
  docker image inspect "$tag" >/dev/null 2>&1 || printf '%s' "$dockerfile" | docker build -q -t "$tag" - >/dev/null
  echo "$tag"
}
# in_container 镜像 [KEY=值…] 命令…：以本机用户身份跑，产物不会变成 root 的；仓库挂在 /src
in_container() {
  local tag=$1 env=()
  shift
  while [[ "${1:-}" == *=* ]]; do env+=(-e "$1"); shift; done
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp "${env[@]}" -v "$root:/src" -w /src "$tag" "$@"
}

# 工具链与 crate 缓存直接用本机的（rustc 自己只要 glibc 2.17），仓库的 rust-toolchain.toml 照样生效
cargo_home=${CARGO_HOME:-$HOME/.cargo}
rustup_home=${RUSTUP_HOME:-$HOME/.rustup}

# deb/rpm 共用 Ubuntu 22.04 里的这一份 Rust 产物；只打 el8/el9 时不要白编一遍
need_ubuntu_rust=0
for format in "${formats[@]}"; do
  case "$format" in deb|rpm) need_ubuntu_rust=1 ;; esac
done
if ((need_ubuntu_rust)); then
  echo '==> Rust：Server 与 IBus 前端（Ubuntu 22.04）'
  rust_image=$(image rust 'FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev ca-certificates && rm -rf /var/lib/apt/lists/*')
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CARGO_HOME=/cargo -e RUSTUP_HOME=/rustup \
    -e CARGO_TARGET_DIR=/src/target/linux-pkg/cargo -v "$root:/src" -v "$cargo_home:/cargo" -v "$rustup_home:/rustup" -w /src \
    "$rust_image" /cargo/bin/cargo build --release --locked -p qingjian-linux-server -p qingjian-linux-ibus
fi
bin="$work/cargo/release"

echo '==> 随包资源'
resources="$work/resources"
sample_flag=()
[[ "${QINGJIAN_SAMPLE:-}" != 1 ]] || sample_flag=(--sample)
python3 "$root/apps/linux/scripts/files.py" resources "$resources" --root "$root" "${sample_flag[@]}"

# Server 与数据那个包的公共部分摆进 $1（系统布局，前缀 /usr）
stage_core() {
  local dest=$1 with_xml=${2:-1}
  install -Dm755 "$bin/qingjian-linux-server" "$dest/usr/bin/qingjian-linux-server"
  install -Dm755 "$bin/qingjian-linux-ibus" "$dest/usr/bin/qingjian-linux-ibus"
  mkdir -p "$dest/usr/share/qingjian"
  cp -r "$resources" "$dest/usr/share/qingjian/resources"
  # 系统目录下的组件 IBus 直接认，不用 install.sh 那套 environment.d。
  # EL 的二进制可能链老 libssl（宿主没有），所以 EL 构建传 0，改在目标容器里生成 XML。
  mkdir -p "$dest/usr/share/ibus/component"
  if ((with_xml)); then
    "$bin/qingjian-linux-ibus" --ibus-xml /usr/bin/qingjian-linux-ibus > "$dest/usr/share/ibus/component/qingjian.xml"
  fi
  mkdir -p "$dest/usr/lib/systemd/user"
  sed 's|@EXEC@|/usr/bin/qingjian-linux-server|' "$root/apps/linux/scripts/qingjian-server.service.in" \
    > "$dest/usr/lib/systemd/user/qingjian-server.service"
  # 托盘按名义尺寸挑图，目录名与像素必须一致（#547），与 files.py 装的同一套
  local size
  for size in 16 22 24 32 48 64 128 256; do
    install -Dm644 "$root/assets/icon/linux/hicolor/${size}x${size}/apps/qingjian.png" \
      "$dest/usr/share/icons/hicolor/${size}x${size}/apps/qingjian.png"
  done
}

build_deb() {
  echo '==> deb（Debian 13）'
  local tag stage="$work/deb" core
  bin="$work/cargo/release"
  tag=$(image deb 'FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cmake g++ make pkg-config dpkg-dev file libfcitx5core-dev libfcitx5utils-dev libfcitx5config-dev nlohmann-json3-dev && rm -rf /var/lib/apt/lists/*')
  rm -rf "$stage"
  core="$stage/qingjian"
  stage_core "$core"
  install -Dm644 "$root/LICENSE" "$core/usr/share/doc/qingjian/copyright"
  in_container "$tag" DEB_VERSION="$deb_version" bash /src/apps/linux/packaging/deb/assemble.sh
  rm -f "$out"/*.deb
  cp "$stage"/*.deb "$out/"
}

build_rpm() {
  echo '==> rpm（Fedora 42）'
  local tag stage="$work/rpm"
  bin="$work/cargo/release"
  tag=$(image rpm 'FROM fedora:42
RUN dnf install -y --setopt=install_weak_deps=False rpm-build cmake gcc-c++ make pkgconf-pkg-config fcitx5-devel json-devel systemd-rpm-macros && dnf clean all')
  rm -rf "$stage"
  stage_core "$stage/root"
  install -Dm644 "$root/LICENSE" "$stage/root/usr/share/licenses/qingjian/LICENSE"
  in_container "$tag" RPM_VERSION="$upstream" RPM_RELEASE="$rpm_release" bash /src/apps/linux/packaging/rpm/assemble.sh
  rm -f "$out"/*.rpm
  cp "$stage"/rpms/x86_64/*.rpm "$out/"
}

# RHEL 8/9 只有 IBus，没有 fcitx5：只出 qingjian 主包。EL 的 glibc 比 Ubuntu 22.04 老，
# 不能复用那边的产物，必须在对应 AlmaLinux 容器里重新编 Rust。
# 这里用的是宿主 rustup 的官方工具链（官方 linux-gnu 产物按 glibc 2.17 构建，预期 EL8 能跑）。
# 万一在 EL8 上因 glibc 版本不行，fallback 是在镜像内装 rustup 1.96.0 再编；先按宿主工具链实现。
build_el() {
  local el=$1
  echo "==> el$el（AlmaLinux $el，IBus-only）"
  local tag stage="$work/el$el"
  bin="$stage/cargo/release"
  tag=$(image "el$el" "FROM almalinux:$el
RUN dnf install -y --setopt=install_weak_deps=False \
      bash coreutils findutils grep sed gawk tar gzip bzip2 xz unzip which \
      gcc gcc-c++ make cmake pkgconf-pkg-config openssl-devel openssl \
      rpm-build redhat-rpm-config ca-certificates curl git-core perl \
      binutils file patch diffutils cpio shadow-utils util-linux procps-ng \
      python3 systemd autoconf automake libtool zlib-devel libcurl-devel \
      sqlite-devel kernel-headers && dnf clean all")
  # 宿主的工具链与 crate 缓存照旧挂进去；CARGO_TARGET_DIR 指到本代的 stage，免得 EL8/EL9 互相覆盖
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CARGO_HOME=/cargo -e RUSTUP_HOME=/rustup \
    -e "CARGO_TARGET_DIR=/src/target/linux-pkg/el$el/cargo" -v "$root:/src" -v "$cargo_home:/cargo" -v "$rustup_home:/rustup" -w /src \
    "$tag" /cargo/bin/cargo build --release --locked -p qingjian-linux-server -p qingjian-linux-ibus
  stage_core "$stage/root" 0
  # XML 在目标容器里生成：EL8 的 IBus 二进制可能链 libssl.so.1.1，宿主（Ubuntu 26.04）没有
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$root:/src" -w /src "$tag" \
    "$bin/qingjian-linux-ibus" --ibus-xml /usr/bin/qingjian-linux-ibus \
    > "$stage/root/usr/share/ibus/component/qingjian.xml"
  install -Dm644 "$root/LICENSE" "$stage/root/usr/share/licenses/qingjian/LICENSE"
  in_container "$tag" EL="$el" RPM_VERSION="$upstream" RPM_RELEASE="$rpm_release" bash /src/apps/linux/packaging/rpm/el/assemble.sh
  rm -rf "$out/el$el"
  mkdir -p "$out/el$el"
  cp "$stage"/rpms/*/*.rpm "$out/el$el/"
}

for format in "${formats[@]}"; do
  case "$format" in
    el8|el9) build_el "${format#el}" ;;
    *) "build_$format" ;;
  esac
done
echo "==> 产物（$out）："
find "$out" -maxdepth 2 -type f -printf '  %p\n' | sort
