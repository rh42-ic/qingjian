#!/usr/bin/env bash
# 把 build.sh 打好的 EL8/EL9 rpm 拿到对应 AlmaLinux 干净容器里装一遍并自检（install.sh，IBus-only）：
#   apps/linux/packaging/smoke/run-el.sh             almalinux:8 / almalinux:9 各跑一次
#   apps/linux/packaging/smoke/run-el.sh el8         只跑 EL8（也可以传镜像名 almalinux:8）
#   apps/linux/packaging/smoke/run-el.sh el8 el9     两代都跑
# 容器里没有图形会话，真会话里切到青简打字还是要人在机器上试。
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out=$(cd -- "$here/../../../.." && pwd)/target/linux-pkg/out
all=('almalinux:8 el8' 'almalinux:9 el9')
failed=0
for spec in "${all[@]}"; do
  read -r image el <<<"$spec"
  if (($#)); then
    match=0
    for want in "$@"; do
      [[ "$want" == "$image" || "$want" == "$el" ]] && match=1
    done
    ((match)) || continue
  fi
  ls "$out/$el"/*.rpm >/dev/null 2>&1 || { echo "没有 $el 包，先跑 apps/linux/packaging/build.sh $el" >&2; exit 2; }
  pkgs=$(mktemp -d)
  cp "$out/$el"/*.rpm "$pkgs/"
  echo "######## $image ($el)"
  docker run --rm -v "$pkgs:/pkgs:ro" -v "$here/install.sh:/install.sh:ro" "$image" bash /install.sh dnf ibus-only || failed=1
  rm -rf "$pkgs"
done
exit "$failed"
