#!/usr/bin/env bash
# 在对应 AlmaLinux 容器里跑（build.sh 调，仓库挂在 /src）：把 EL8/EL9/EL10 的 IBus-only qingjian 主包打出来。
# EL8 另有可选的 Fcitx4 子包（QJ_FCITX4=1 时编，依赖 EPEL 的 fcitx-devel）；主包本身不依赖 Fcitx4。
# Server、IBus 前端、词库、服务与图标 build.sh 已经摆好在 $stage/root；这里只补 Fcitx4 插件、剥符号、归一权限，再走 el/qingjian.spec。
set -euo pipefail
stage=/src/target/linux-pkg/el${EL:?}
root="$stage/root"
libdir=$(rpm --eval '%{_libdir}')

# 防止和 Fedora / 另一代 EL 的 dist 重名：AlmaLinux 8 应该是 .el8*，9 是 .el9*，10 是 .el10*
dist=$(rpm --eval '%{?dist}')
case "$dist" in
  ".el$EL"*) ;;
  *) echo "dist 不对：期望 .el$EL*，实际 '$dist'（在 almalinux:$EL 里跑？）" >&2; exit 1 ;;
esac

fcitx4=0
if [[ "${QJ_FCITX4:-0}" == 1 ]]; then
  [[ "$EL" == 8 ]] || { echo 'QJ_FCITX4=1 只支持 EL8' >&2; exit 1; }
  fcitx4=1
  build="$stage/fcitx4-build"
  cmake -S /src/apps/linux/fcitx4 -B "$build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DQJ_CXX_STANDARD=17 >/dev/null
  cmake --build "$build" --parallel >/dev/null
  install -Dm755 "$build/fcitx-qingjian.so" "$root$libdir/fcitx/fcitx-qingjian.so"
  install -Dm644 /src/apps/linux/fcitx4/data/addon/fcitx-qingjian.conf "$root/usr/share/fcitx/addon/fcitx-qingjian.conf"
  install -Dm644 /src/assets/icon/fcitx4.png "$root/usr/share/fcitx/imicon/qingjian.png"
  install -Dm644 /src/assets/icon/fcitx4.png "$root/usr/share/icons/hicolor/48x48/apps/fcitx-qingjian.png"
fi

strip --strip-unneeded "$root/usr/bin/qingjian-linux-server" "$root/usr/bin/qingjian-linux-ibus"
[[ "$fcitx4" == 0 ]] || strip --strip-unneeded "$root$libdir/fcitx/fcitx-qingjian.so"
# 宿主机 umask 是 002 时拷出来的是 664 / 775；/usr/bin 下的程序保留可执行
find "$root" -type d -exec chmod 755 {} +
find "$root" -type f ! -path '*/usr/bin/*' -exec chmod 644 {} +

define=()
[[ "$fcitx4" == 0 ]] || define+=(--define "qj_fcitx4 1")
rpmbuild -bb /src/apps/linux/packaging/rpm/el/qingjian.spec \
  --define "_topdir $stage/rpmbuild" --define "_rpmdir $stage/rpms" \
  --define "qj_root $root" --define "qj_version ${RPM_VERSION:?}" --define "qj_release ${RPM_RELEASE:?}" \
  --define "qj_el $EL" "${define[@]}" >/dev/null
ls "$stage"/rpms/*/*.rpm
