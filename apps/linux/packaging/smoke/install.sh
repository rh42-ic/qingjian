#!/bin/bash
# 在容器里跑（run.sh / run-el.sh 调）：装 /pkgs 下的包（默认两包；IBus-only 时只有 qingjian 主包），
# 确认自启登记、IBus 组件与插件依赖，起 Server 用包里的
# qingjian-linux-ibus --check 打 nihao（走的是真前端的那套客户端代码，不另抄协议），配置里打开本地整句模型、等它加载完，
# 再卸载看自启登记与组件有没有清掉。$1 = apt / dnf / zypper；$2 = full（默认）/ ibus-only；任一项不对退出码非 0
set -e
mode=${2:-full}
fail() { echo "失败：$*"; exit 1; }
case $1 in
  apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq systemd >/dev/null 2>&1
       apt-get install -y -qq /pkgs/qingjian_*.deb /pkgs/qingjian-fcitx5_*.deb >/dev/null 2>&1 || { apt-get install -y /pkgs/*.deb 2>&1 | tail -6; exit 1; }
       echo "装上：$(dpkg-query -W -f='${Package} ${Version}  ' qingjian qingjian-fcitx5)" ;;
  dnf) dnf install -y -q systemd >/dev/null 2>&1
       if [ "$mode" = ibus-only ]; then
         dnf install -y -q /pkgs/qingjian-[0-9]*.rpm >/dev/null 2>&1 || { dnf install -y /pkgs/qingjian-[0-9]*.rpm 2>&1 | tail -6; exit 1; }
         echo "装上：$(rpm -q qingjian ibus | tr '\n' ' ')"
       elif [ "$mode" = fcitx4 ]; then
         dnf install -y -q epel-release >/dev/null 2>&1 || { dnf install -y epel-release 2>&1 | tail -6; exit 1; }
         dnf install -y -q /pkgs/qingjian-[0-9]*.rpm /pkgs/qingjian-fcitx4-*.rpm >/dev/null 2>&1 || { dnf install -y /pkgs/qingjian-[0-9]*.rpm /pkgs/qingjian-fcitx4-*.rpm 2>&1 | tail -6; exit 1; }
         echo "装上：$(rpm -q qingjian qingjian-fcitx4 fcitx | tr '\n' ' ')"
       else
         dnf install -y -q /pkgs/*.rpm >/dev/null 2>&1 || { dnf install -y /pkgs/*.rpm 2>&1 | tail -6; exit 1; }
         echo "装上：$(rpm -q qingjian qingjian-fcitx5 | tr '\n' ' ')"
       fi ;;
  zypper) zypper -q -n install systemd >/dev/null 2>&1; zypper -q -n --no-gpg-checks install --allow-unsigned-rpm /pkgs/*.rpm >/dev/null 2>&1 || { zypper -n --no-gpg-checks install --allow-unsigned-rpm /pkgs/*.rpm 2>&1 | tail -6; exit 1; }
       echo "装上：$(rpm -q qingjian qingjian-fcitx5 | tr '\n' ' ')" ;;
esac
if [ "$mode" = ibus-only ]; then
  case $1 in
    apt) dpkg-query -W qingjian ibus >/dev/null 2>&1 || fail "qingjian 或 ibus 没装上" ;;
    *) rpm -q qingjian ibus >/dev/null 2>&1 || fail "qingjian 或 ibus 没装上" ;;
  esac
elif [ "$mode" = fcitx4 ]; then
  rpm -q qingjian qingjian-fcitx4 fcitx >/dev/null 2>&1 || fail "qingjian / qingjian-fcitx4 / fcitx 没装上"
fi
wants=/etc/systemd/user/default.target.wants/qingjian-server.service
echo "自启登记：$(readlink $wants || echo 没有)"
[ -L $wants ] || fail "Server 没登记成随会话自启"
xml=/usr/share/ibus/component/qingjian.xml
exec_path=$(sed -n 's|.*<exec>\([^ <]*\).*|\1|p' $xml 2>/dev/null)
echo "IBus 组件：$xml，exec=${exec_path:-没有}"
[ -x "$exec_path" ] || fail "IBus 组件不在或 exec 指向的文件不存在"
if [ "$mode" = ibus-only ]; then
  echo "插件：ibus-only，跳过 fcitx5 插件检查"
elif [ "$mode" = fcitx4 ]; then
  so=$(ls /usr/lib*/fcitx/fcitx-qingjian.so /usr/lib/*/fcitx/fcitx-qingjian.so 2>/dev/null | head -1)
  missing=$(ldd "$so" | grep -c 'not found' || true)
  echo "Fcitx4 插件：$so，缺库：$missing"
  [ -n "$so" ] && [ "$missing" = 0 ] || fail "Fcitx4 插件不在或缺库"
  [ -f /usr/share/fcitx/addon/fcitx-qingjian.conf ] || fail "Fcitx4 addon 配置不在"
else
  so=$(ls /usr/lib*/fcitx5/qingjian.so /usr/lib/*/fcitx5/qingjian.so 2>/dev/null | head -1)
  missing=$(ldd "$so" | grep -c 'not found' || true)
  echo "插件：$so，缺库：$missing"
  [ -n "$so" ] && [ "$missing" = 0 ] || fail "fcitx5 插件不在或缺库"
fi
export XDG_RUNTIME_DIR=/tmp/run HOME=/root; mkdir -p $XDG_RUNTIME_DIR
# 本地整句模型缺省关，打开它才验得到随包的含章·通变能加载
mkdir -p /root/.config/qingjian
printf '[model]\nenabled = true\nname = "tongbian"\n' > /root/.config/qingjian/config.toml
qingjian-linux-server >/tmp/server.out 2>&1 &
for _ in $(seq 1 60); do [ -S $XDG_RUNTIME_DIR/qingjian.sock ] && break; sleep 0.5; done
# --check 的日志与结果都在 stdout：只留「打了…」起的那几行，候选压成一行
check=$(qingjian-linux-ibus --check nihao 2>&1) || fail "--check 出错：$(echo "$check" | tail -3)"
echo "$check" | sed -n '/打了「/,$p' | tr -s ' \n' ' '; echo
echo "$check" | grep -q '（没有候选）' && fail "打 nihao 没有候选（词库没找到？）"
logs=/root/.local/state/qingjian/logs
for _ in $(seq 1 120); do grep -qs "本地整句模型已加载并预热\|本地整句模型加载失败\|没有本地整句模型文件" $logs/* && break; sleep 0.5; done
model=$(grep -hs "本地整句模型" $logs/* | sed 's/\x1b\[[0-9;]*m//g' | grep -o '本地整句模型[^ ]*\|kind=[^ ]*' | tr '\n' ' ')
echo "模型：${model:-没等到日志}"
grep -qs "本地整句模型已加载并预热" $logs/* || fail "本地整句模型没加载上"
if [ "$mode" = ibus-only ]; then
  case $1 in apt) apt-get remove -y -qq qingjian >/dev/null 2>&1 ;; *) rpm -e qingjian ;; esac
elif [ "$mode" = fcitx4 ]; then
  case $1 in apt) apt-get remove -y -qq qingjian-fcitx4 qingjian >/dev/null 2>&1 ;; *) rpm -e qingjian-fcitx4 qingjian ;; esac
else
  case $1 in apt) apt-get remove -y -qq qingjian-fcitx5 qingjian >/dev/null 2>&1 ;; *) rpm -e qingjian-fcitx5 qingjian ;; esac
fi
echo "卸载后：自启登记$( [ -e $wants ] && echo 还在 || echo 已清)，IBus 组件$( [ -e $xml ] && echo 还在 || echo 已清)"
[ ! -e $wants ] && [ ! -e $xml ] || fail "卸载没清干净"
echo "通过"
