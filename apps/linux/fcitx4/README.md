# Fcitx4 插件

Ubuntu 22.04 的 Fcitx4 壳，复用 `apps/linux/server` 与 Fcitx5 插件的 Unix socket 传输实现。
使用 Fcitx4 默认面板；用户安装命令为 `apps/linux/scripts/install.sh --fcitx4`，见 [Linux 安装说明](../../../docs/user/platforms/linux.md)。
RHEL 8 的 Fcitx4 来自 EPEL；EL8 的 RPM 另出可选 `qingjian-fcitx4` 子包，主包仍只走 IBus。
开发接口和已验证范围见 [工程说明](../../../docs/notes/linux-fcitx4.md)。
