#!/usr/bin/env bash
# 在对应 AlmaLinux 容器里跑（build.sh 调，仓库挂在 /src）：把 EL8/EL9 的 IBus-only qingjian 主包打出来。
# Server、IBus 前端、词库、服务与图标 build.sh 已经摆好在 $stage/root；这里只剥符号、归一权限，再走 el/qingjian.spec。
set -euo pipefail
stage=/src/target/linux-pkg/el${EL:?}
root="$stage/root"

# 防止和 Fedora / 另一代 EL 的 dist 重名：AlmaLinux 8 应该是 .el8*，9 是 .el9*
dist=$(rpm --eval '%{?dist}')
case "$dist" in
  ".el$EL"*) ;;
  *) echo "dist 不对：期望 .el$EL*，实际 '$dist'（在 almalinux:$EL 里跑？）" >&2; exit 1 ;;
esac

strip --strip-unneeded "$root/usr/bin/qingjian-linux-server" "$root/usr/bin/qingjian-linux-ibus"
# 宿主机 umask 是 002 时拷出来的是 664 / 775；/usr/bin 下的程序保留可执行
find "$root" -type d -exec chmod 755 {} +
find "$root" -type f ! -path '*/usr/bin/*' -exec chmod 644 {} +

rpmbuild -bb /src/apps/linux/packaging/rpm/el/qingjian.spec \
  --define "_topdir $stage/rpmbuild" --define "_rpmdir $stage/rpms" \
  --define "qj_root $root" --define "qj_version ${RPM_VERSION:?}" --define "qj_release ${RPM_RELEASE:?}" \
  --define "qj_el $EL" >/dev/null
ls "$stage"/rpms/*/*.rpm
