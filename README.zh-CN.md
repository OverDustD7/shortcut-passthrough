# shortcut-passthrough

[English](README.md) | 简体中文

[![Release](https://img.shields.io/github/v/release/OverDustD7/shortcut-passthrough?style=flat)](https://github.com/OverDustD7/shortcut-passthrough/releases)
[![Android](https://img.shields.io/badge/Android-8%2B-3DDC84?style=flat)](#环境要求)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?style=flat)](#环境要求)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat)](LICENSE)
[![GitHub source](https://img.shields.io/badge/GitHub-source-24292e?style=flat)](https://github.com/OverDustD7/shortcut-passthrough)

通过 Android 无障碍服务和 UDP 接收器，把平板物理键盘的 Alt+Tab、Win 组合键送到 Windows 主机。不需要 root 或修改远控客户端。

## 发布与维护状态

维护中。徽章指向已发布 APK；源码中的修改可能晚于该版本。

Alt+Tab 可在平板侧拦截；部分 Win 组合键仍会同时作用于平板和主机。已有设备记录使用 Moonlight，其它客户端和厂商系统仍需各自验证。

## 环境要求

- Android 8.0 / API 26 以上、物理键盘，以及启用无障碍服务的权限。
- Windows 10/11、Windows PowerShell 5.1。
- 可信网络，以及在平板和 Windows 主机之间私下传递的配对码。
- 编译需要预先安装 Android SDK build-tools、Android platform 和兼容 JDK。已有构建记录使用 JDK 17，最低 JDK 版本本轮未重新验证。

## 安装

配对传输使用 1.7 源码。需同时更新平板 APK 和 Windows 主机目录。现有 1.6 明文协议与新接收器不兼容；没有匹配发布时可从本地源码构建。

从匹配 1.7 的 [Releases](https://github.com/OverDustD7/shortcut-passthrough/releases) 下载 `shortcut-passthrough.apk` 并安装。系统若限制侧载应用启用无障碍服务，先审阅应用的受限设置再启用。

Windows 端从同一源码版本取得完整 `host/` 目录，将 `install-autostart.ps1`、`receiver-identity.ps1`、`alttab-recv.ps1` 放在同一个纯 ASCII 路径下：

~~~powershell
.\host\setup-pairing.ps1
.\host\setup-pairing.ps1 -Show
.\host\install-autostart.ps1
~~~

脚本启动隐藏接收器，并写入当前用户的启动文件夹；不安装服务或计划任务。只有新启动的进程确实占有所选 UDP 端口，才报告启动验证成功。

端口被其它进程占用、自启动项内容无法确认，或系统不允许读取所需进程身份时，安装会停止，不猜测要终止哪个进程。

## 快速使用

1. 在平板打开 **Shortcut Passthrough**。
2. 填主机地址（不含端口、方括号）、UDP 端口（默认 `47823`）、主机配对码和目标包名前缀，例如 `com.limelight`。点击「验证主机配对」检查连接。
3. 启用无障碍服务。目标列表为空时不拦截；`*` 表示在所有应用中拦截。
4. 目标应用处于前台时，试用 Alt+Tab 和所需的 Win 组合键。

界面会显示服务/过滤状态及包计数。还应确认主机执行了正确按键，并在离开目标应用后释放已按下的键；计数增加本身不能证明主机输入成功。

## 配置、数据与权限

Android 端读取无障碍窗口信息来识别前台应用、过滤快捷键，并申请网络、前台服务、通知及可选的电池优化豁免权限。配置和诊断留在应用存储或内存中；manifest 已禁用 Android 备份。

快捷键事件发送到配置的主机。接收器在本地日志记录包类型、键码和来源地址。前台包名、地址、日志及截图可能暴露使用情况，分享前须脱敏。

平板和接收器先验证共享配对码。命令使用 AES-256-CBC 加密，并用独立密钥做 HMAC-SHA256 认证。接收器拒绝旧版明文、错误配对码、篡改、重复或乱序序号，以及上次接收器运行的报文。Windows 使用当前用户 DPAPI 保存配对码，Android 将其保存在应用私有设置中。请私下传递配对码，并将局域网端口限制给自己的平板。

APK 使用项目的 debug keystore 签名，它不是私有的生产签名身份。正式分发的签名和信任方案仍须另行落实。

## 升级与卸载

升级主机端时保留完整 `host/` 目录。更换签名密钥前先核 Android 的升级和数据保留条件；本项目不会自动轮换密钥。

删除当前目录对应的接收器与自启动项：

~~~powershell
.\host\install-autostart.ps1 -Uninstall
~~~

使用过自定义端口时，卸载也要传相同 `-Port`。核验会同时检查脚本、可信 PowerShell 可执行文件、当前用户/会话、参数和进程创建身份；无法确认的启动方式原样保留，交由人工核对。

主机日志和源码不会删除。Android 端先禁用无障碍服务，再卸载应用；应用内设置按 Android 的正常卸载行为移除。

## 已知限制与排错

- Win 组合键仍可能作用于 Android；完整屏蔽厂商系统行为不在无 root 方案内。
- 过滤器生效期间，每个物理键仍有一次同步往返。
- UDP 尽力送达；本地顺序与主机的八秒卡键看守都不等于可靠投递。
- 重装后服务已启用却未连接时，重新开关无障碍服务并检查状态。
- 只处理单向键盘事件，不是鼠标或通用文本输入通道。
- 端口冲突或自启动项身份不明时不会覆盖或停进程；先核归属，或使用其它端口。
- 正式发行仍需单独确定签名策略。

## 开发与详细文档

使用本机 SDK/JDK 编译：

~~~powershell
$env:ANDROID_HOME = '{{ANDROID_SDK}}'
$env:JAVA_HOME = '{{JDK_DIR}}'
.\build.ps1
~~~

产物为 `build/shortcut-passthrough.apk`；根目录缺少 `debug.keystore` 时会创建它。构建使用已安装工具，不下载依赖。

在新的 Windows PowerShell 进程中运行接收器身份回归：

~~~powershell
powershell.exe -NoLogo -NoProfile -File .\test\ReceiverIdentityTest.ps1
~~~

该测试使用虚构元数据和自行创建的休眠进程；不启动键盘接收器、不监听 UDP、不安装自启动项、不注入按键。

[实现说明与历史设备验证](docs/IMPLEMENTATION.zh-CN.md)保留输入分发、过滤器、协议、队列/释放处理、历史测量和文件结构；其中设备测量不代表本轮重新完成了设备验收。

## 反馈与安全报告

非敏感问题提交到 [Issues](https://github.com/OverDustD7/shortcut-passthrough/issues)。目前不提供已公布的私密安全报告渠道；不要在公开页面贴按键内容、私人地址、账号、完整日志或未脱敏截图。

## 许可证与第三方说明

MIT，见 [LICENSE](LICENSE)，保留其中原有版权声明。文中提到的远控客户端属于独立项目，不随本项目分发。
