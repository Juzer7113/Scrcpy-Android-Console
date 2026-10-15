<div align="center">

# 📱 Scrcpy 安卓控制台

**基于 scrcpy 的局域网安卓设备可视化管理平台 —— 一个浏览器标签页，镜像并操控所有机顶盒、模拟器、手机和平板。**

[English](README.md) | **简体中文**

[![平台](https://img.shields.io/badge/平台-Windows-0078D6?style=flat-square)](https://github.com/Juzer7113/Scrcpy-Android-Console)
[![零依赖](https://img.shields.io/badge/运行时-零依赖-brightgreen?style=flat-square)](https://github.com/Juzer7113/Scrcpy-Android-Console)
[![许可证](https://img.shields.io/badge/许可证-Apache--2.0-blue?style=flat-square)](LICENSE)
[![下载](https://img.shields.io/badge/下载-v1.0.0-orange?style=flat-square)](releases/Scrcpy-Android-Console-v1.0.0.zip)

</div>

---

## ✨ 为什么做这个项目

管理一批安卓设备，通常意味着开一堆 `adb` 终端、背几十条 `adb connect IP:5555`、
还要跟 scrcpy 的一堆参数较劲——一次只能连一台。

**Scrcpy 安卓控制台**把 [scrcpy](https://github.com/Genymobile/scrcpy) 和 `adb`
包装成一个自包含的 Web 控制台：填 IP 添加设备，点「连接并控制」，实时画面弹窗即现，
鼠标键盘全控制。不用装 Python、不用装 Node、不用装 Android SDK——
**唯一运行时是 Windows 自带的 PowerShell**。

适用场景：

- 🖥️ **机顶盒 / 电视盒集群** —— 酒店 IPTV 盒子、OTT 盒子、测试台
- 📺 **模拟器农场** —— MuMu、BlueStacks、LDPlayer、AVD 一字排开
- 🏪 **设备实验室 / 门店** —— 演示机、自助终端、零售展位
- 🔧 **所有第 100 次敲 `adb connect` 敲烦了的人**

## 📸 截图

| 控制台主页 | 实时画面与控制 | 一键卸载应用 |
|:---:|:---:|:---:|
| <img src="screenshots/console-dashboard.png" width="280"/> | <img src="screenshots/live-mirroring.png" width="280"/> | <img src="screenshots/app-uninstall.png" width="280"/> |

## 🚀 快速开始

1. 下载便携包（16 MB）：
   **[`Scrcpy-Android-Console-v1.0.0.zip`](https://github.com/Juzer7113/Scrcpy-Android-Console/releases/download/v1.0.0/Scrcpy-Android-Console-v1.0.0.zip)**
   —— 仓库里也存了一份：
   [`releases/Scrcpy-Android-Console-v1.0.0.zip`](releases/Scrcpy-Android-Console-v1.0.0.zip)
2. 解压到任意位置。**无需安装，无需配置。**
3. 双击 **`启动控制台.bat`**
4. 浏览器自动打开 **<http://127.0.0.1:8000>** —— 控制台就跑起来了

> 黑色窗口就是服务本体，关窗口即停止。页面没自动打开？手动访问
> `http://127.0.0.1:8000`（端口固定不变）。

## 📖 使用方式

### 1. 添加设备

填 **设备 IP**（端口默认 `5555`）和备注名（如 `前台 / 305 房`）→ 点「添加设备」→ 生成设备卡片。

- 🟢 绿点 = 在线，⚪ 灰点 = 离线（每 30 秒自动探测，也可手动「刷新状态」）
- **Android 11+**：需先在「开发者选项 → 无线调试」里配对一次：`adb pair IP:配对端口`
- **Android 10 及以下**：多数默认开放 5555，直接添加即可

### 2. 连接并控制

点卡片上的「连接并控制」→ 弹出该设备的实时画面窗口。

| 操作 | 效果 |
|---|---|
| 鼠标点击 | 触摸 |
| 方向键 | 遥控器方向键（机顶盒绝配） |
| 回车 | 确认 |
| **鼠标右键** | 返回 |

### 3. 安装 APK

点卡片「安装 APK」→ 选择电脑上的 `.apk` → 自动上传并推送安装（覆盖安装，保留数据）。

### 4. 卸载应用

点卡片「卸载」→ 弹窗列出该设备的第三方应用：**图标、名称、包名、大小**，支持搜索。
点行尾「卸载」→ 二次确认 → 执行。

> 每台设备首次打开略慢（需拉取 APK 解析图标），之后走缓存秒开。
> 缓存目录 `scrcpy\cache\apps\`，随时可删。

### 5. 单机直连（不经过 Web）

双击 `scrcpy\connect.bat` → 输入 IP → 直接弹窗。适合快速连一台设备调试，不用起 Web 服务。

## 🏗️ 整体架构

```
浏览器 index.html
    │  HTTP（仅 127.0.0.1 回环，不暴露局域网）
    ▼
server.ps1（PowerShell 5.1 + .NET HttpListener，端口 8000）
    │  调用同目录可执行文件
    ├── adb.exe         设备发现、连接、装包、卸载、文件拉取
    ├── scrcpy.exe      画面推流 + 键鼠控制
    └── tools\aapt2.exe 解析 APK 内的应用名与图标
```

**为什么必须有本地后端**：浏览器安全策略禁止网页直接启动电脑上的 exe，必须由本地服务中转。
这也是不采用纯 HTML 方案的原因。

**为什么用 PowerShell 不用 Python**：目标机器零安装——Windows 自带 PowerShell 5.1，
不用装 Python / Node / Android SDK / Visual C++ 运行库。

## 🧰 工程亮点

- **零依赖、全便携** —— 整个文件夹拷到新电脑双击即用。已逐项审计：无绝对路径硬编码
  （bat 用 `%~dp0`、ps1 用 `$MyInvocation` 自推导位置）、全部 DLL 已打包、
  只绑 127.0.0.1 回环（不弹防火墙窗口）、脚本纯 ASCII 编码（无乱码风险）。
- **编码参数按机型自适应** —— 启动时读设备 `ro.product.model`：SW-618 机顶盒用专用
  硬编 + 全 I 帧方案（绕开该固件编码器码流 bug，否则 FFmpeg 狂报
  `QP out of range`），其他设备用默认保守参数（1024 宽 / 30fps / 4M）。
- **真实应用图标** —— 逐个拉取 APK，用 aapt2 解析 label，从 zip 中提取图标
  （PNG/WebP/JPG）；矢量 XML 图标浏览器渲染不了，回落首字母头像。
- **智能图标缓存** —— `cache\apps\<包名>\meta.json` 记录 APK 路径，应用更新导致路径变化时
  缓存自动失效重拉。
- **UTF-8 强制解码** —— 进程输出强制按 UTF-8 解析，高棉语、中文等非 ASCII 应用名不乱码。

## ⚠️ 已知限制

1. **Android 11 以下设备不支持音频转发**（scrcpy 服务端限制），控制画面和键鼠不受影响
2. 部分机顶盒硬件编码器输出码流不规范（典型症状：FFmpeg 报 `QP out of range` /
   `reference frames` 错），SW-618 已有专用方案；其他机型在 `Video-Args-For` 里加对应分支即可
3. 应用名为矢量图标的（少数应用）显示首字母头像
4. 首次打开某设备的卸载列表要拉取全部 APK，应用多时会等十几秒，之后有缓存
5. 同时开太多画面窗口会占满 CPU（每路 = 一次 H.264 解码），建议同屏不超过 8 路，
   其余用 ADB 命令批量操作

## 📄 许可证

控制台封装代码（`server.ps1`、`index.html`、启动脚本）采用 **Apache-2.0** 许可证。
本项目打包了 [scrcpy](https://github.com/Genymobile/scrcpy)（© Genymobile，同为
Apache-2.0）—— 见 [`scrcpy/LICENSE.txt`](scrcpy/LICENSE.txt)。

## ⭐ 觉得有用？

点个 Star，让同样在被 `adb connect` 折磨的人找到这里。
