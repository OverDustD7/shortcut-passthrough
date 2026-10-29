# shortcut-passthrough

[![GitHub](https://img.shields.io/badge/GitHub-OverDustD7%2Fshortcut--passthrough-24292e)](https://github.com/OverDustD7/shortcut-passthrough)

[English](README.md) | 简体中文

把平板物理键盘上的 Alt+Tab 以及所有带 Win 的组合键送到 Windows 主机，不 root，也不改远控客户端。平板继续显示串流画面，不会再跳去自己的「最近任务」。

Android 的输入分发在 `interceptKeyBeforeDispatching` 里就把 Alt+Tab 消化掉了，带 Win 的组合键更早，在 `interceptKeyBeforeQueueing` 就处理，所以远控客户端根本收不到。本应用站在这两者之间的无障碍按键过滤上：在那里把键吃掉，用 UDP 发给主机，由主机脚本用 `keybd_event` 真正按出来。

## 需要什么

- 平板：Android 8.0（API 26）以上、一把物理键盘、一个你想继续用的远控客户端（与 Moonlight 实测过）。
- 主机：Windows 10/11，Windows PowerShell 5.1。
- 想自己编译：Android SDK（含 `build-tools` 与任一 `platforms/android-*`）+ JDK 8 以上（17 实测）。不需要 Gradle，也不需要联网。

## 安装

### 用 Release 里的 APK（推荐）

从 [最新 release](https://github.com/OverDustD7/shortcut-passthrough/releases/latest) 下载 `shortcut-passthrough.apk` 装到平板。Android 13 以上，侧载应用要先在应用信息里打开「允许受限设置」，无障碍服务才开得起来。

### 从源码编译

```powershell
$env:ANDROID_HOME = 'C:\Android\Sdk'          # 或用 -Sdk 传
$env:JAVA_HOME    = 'C:\Program Files\Java\jdk-17'
.\build.ps1
# -> build\shortcut-passthrough.apk
```

脚本自动挑最新的 `build-tools` 与 `platform`，依次做 aapt2 编译资源、javac、d8 转 dex、zipalign、apksigner 签名（首次运行生成一个本地 debug keystore），除 `build/` 外不写任何东西。

### 主机端

```powershell
.\host\install-autostart.ps1              # 现在就启动，并写入启动文件夹
.\host\install-autostart.ps1 -Uninstall   # 删除启动项并停掉监听
```

监听器以你自己账号下的隐藏 PowerShell 进程运行，不需要管理员、不需要计划任务或系统服务。

## 用法

1. 打开平板上的「快捷键直通」，填三项：
   - **主机地址**：主机脚本启动时会打印本机所有可用地址，填其中一个，IPv4 或 IPv6，不带端口、不加方括号；
   - **端口**：默认 `47823`；
   - **接管名单**：允许接管的包名前缀，默认 `com.limelight`。留空表示一律不接管（安全默认），只有确实想在所有应用里接管时才写 `*`。
2. 开启无障碍服务，应用里有按钮直接跳到设置页。
3. 键盘上按 Alt+Tab、Win、Win+D、Win+Shift+S、Win+E。

应用首页会显示过滤状态、当前前台应用、最近经过的包名、回调耗时、报文计数，还有一个自检按钮。这些数据都只留在设备上。

## 怎么工作

```
平板键盘 -> 无障碍按键过滤 -> UDP -> 主机脚本 -> keybd_event
```

- 只在目标应用前台时才申请过滤。过滤一旦开着，每个实体按键都要同步等本应用回话，所以不在目标应用时就关掉，正常打字完全不经过它。
- 前台应用取自 `getRootInActiveWindow()`，后备是 `getWindows()` 里的应用窗口，**不采信事件里的包名**。通知、输入法、系统对话框也会发窗口事件，照它们的包名开关会把过滤误关掉，表现出来就是时好时坏。
- 按键回调只做整数判断和一次入队：不拼字符串、不读配置、不解析域名、不发网络。
- 抬起按归属判定（本应用真正吞过哪些键），不看当前修饰位，否则 `Win↓ D↓ Win↑ D↑` 会漏掉最后的 `D↑`。
- 发送集中在一条线程一个 socket，顺序不乱，输入回调不会被网络拖住。
- 队列满时，关键报文（抬起）丢失会换成一条延后补发的 `RELEASE_ALL`；普通报文丢弃。
- 离开目标应用、服务被解绑、进程退出，都会发 `RELEASE_ALL`，主机不会留着按住的键。

## 协议

| 报文 | 含义 |
|---|---|
| `ALT_TAB` / `ALT_TAB_REV` | 主机注入 Alt+Tab / Shift+Alt+Tab |
| `KEY <androidKeyCode> <1\|0>` | 按下或抬起对应的 Windows 键 |
| `RELEASE_ALL` | 松开主机上所有还按着的键 |
| `PING` | 只记日志，用来测通不通 |

UDP 是尽力而为。能保证的只有本地发送顺序；丢包由主机侧 8 秒卡键超时兜底，不做重传。

## 验证

模拟器 Android 15（API 35），用 `sendevent` 从内核层打真实按键：

| 场景 | 结果 |
|---|---|
| 目标应用不在前台 | 无回调、无报文 |
| 目标应用前台，连发 30 个普通字符 | 回调预热后 ≤27 微秒（首键冷启动 2.4 毫秒），不发任何报文 |
| `Win↓ D↓ Win↑ D↑` | 四条报文，顺序正确，最后的抬起也在 |
| `Alt↓ Tab↓ Alt↑ Tab↑` | 只发一条 `ALT_TAB`，`Tab` 抬起没有泄漏 |
| 先发一条系统通知，再按 Alt+Tab | 仍然转发；系统窗口不再能把过滤关掉 |
| 离开目标应用 | `filter=false`，主机收到 `RELEASE_ALL -> released 1 held key(s)` |
| 主机不可达或域名解析不了 | 回调仍约 0.1 毫秒，进程不阻塞 |

`KeyPolicy` 与 `ReleaseSafeQueue` 是纯 Java，`test/PipeCoreTest.java` 在 JVM 上就能跑，不需要设备：`pass=9 fail=0`。

## 边界

- **Win 组合键在平板上仍然会生效。** 系统在应用之前就处理 Meta。本应用只保证主机那边也按出来，拦不住设备自己。要压掉设备侧只能 root，例如用 Xposed 模块关掉厂商的 Win 快捷键，或者换一把不发这些键的键盘。
- 串流期间过滤必须开着，这段跨进程往返消不掉，只能压短。
- 如果显示「无障碍已开启」但没反应，把无障碍服务关一次再开。覆盖安装可能留下「已启用但未绑定」，应用里会显示成「服务实例：未连接」。
- 只做键盘、只做单向；鼠标与文本输入不碰。

## 目录

```
AndroidManifest.xml           平板端应用，不用 Gradle
build.ps1
res/                          文案与无障碍服务配置
src/top/overdustd7/alttabpipe/
    AltTabPipeService.java      无障碍服务：过滤开关与前台判定
    KeyPolicy.java              按键归属判定，纯 Java
    ReleaseSafeQueue.java       发送队列与释放兜底，纯 Java
    MainActivity.java           配置与诊断界面
test/PipeCoreTest.java        纯 JVM 测试，不需要设备
host/
    alttab-recv.ps1             UDP 监听与按键注入
    serve-apk.ps1               单文件 HTTP 下载页，把 APK 送到平板
    install-autostart.ps1       独立启动 + 登录自启
```

## 许可

MIT，见 [LICENSE](LICENSE)。
