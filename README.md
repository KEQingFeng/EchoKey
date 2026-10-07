# EchoKey

把有线 USB‑C EarPods（线控版）耳机线上的三个实体按键，重映射成任意键盘动作的 macOS 菜单栏小工具。

原生 Swift + AppKit，无第三方依赖，不用 Xcode、不用 Homebrew，一条命令即可构建出 `.app`。

## 用途

EarPods 线控上的「音量＋ / 中键 / 音量－」在系统里只能触发固定的媒体功能（调音量、播放/暂停、切歌），无法改键。EchoKey 常驻菜单栏，拦截这三个按键，按你的配置改写成普通键盘按键，并可选地把原始媒体行为吞掉。

典型场景：把中键变成 `Delete`、音量键变成修饰键或回车，这样单手就能在编辑器里翻页、删除、确认。

仓库里附带的示例配置 `EchoKey.json` 是一套可用的映射：

| 物理按键 | 触发 | 映射为 |
| --- | --- | --- |
| 中键 单击 | `play_or_pause` | `⌃↑` 调度中心 |
| 中键 双击 | `scan_next_track` | `⌃↓` App 窗口 |
| 中键 三击 | `scan_previous_track` | `⌘⇧4` 区域截图 |
| 音量＋ | `volume_increment` | `fn`（地球键） |
| 音量－ | `volume_decrement` | `Enter` |

这套映射只是示例。实际生效的是运行期配置（见下），改完 JSON 重启应用即可换成任何你想要的键。

## 工作原理

有线 EarPods 的按键会同时走两条通道，EchoKey 两条都接：

- **CGEventTap**（`NSSystemDefined` 通道）：负责识别媒体键，并且这是唯一能「吞掉」原始按键的通道。返回 `nil` 即拦截，系统不再执行原本的播放/暂停、调音量。
- **IOHIDManager**（HID Consumer 通道）：作为补充识别按键，HID 输入本身无法拦截，仅用于提高识别率、并在 tap 通道异常时兜底。

另外针对 tap 会被系统在超时或用户输入后自动关闭的问题，实现了自愈：监听 `.tapDisabledByTimeout` / `.tapDisabledByUserInput` 事件重新启用，并有 3 秒一次的定时健康检查，权限授予晚于启动时也能自动补建监听。

## 构建

```bash
bash build.sh
```

产物为 `dist/EchoKey.app`，双击即可运行（首次运行会请求系统权限，见下）。

构建脚本优先用本机钥匙串里的 **Apple Development** 证书签名；找不到证书时回退 ad‑hoc 签名。注意：ad‑hoc 签名下每次重新构建，系统已授予的权限都会失效、需要重新勾选；用稳定证书签名可保持权限不变。

## 系统权限

EchoKey 需要两项权限，首次运行后到 **系统设置 → 隐私与安全性** 中勾选：

- **辅助功能**：创建 CGEventTap，识别并改写按键事件。
- **输入监控**：通过 IOHIDManager 读取 HID 输入。

两项缺一不可。菜单栏点开「按键测试…」可查看当前权限状态与实时收到的事件（来源标记 `tap` 或 `hid`）。

## 运行期配置

生效的配置放在：

```
~/.config/echokey/config.json
```

格式兼容 Karabiner 的 `complex_modifications`，字段与仓库里的 `EchoKey.json` 一致。关键字段：

- `rules`：映射规则数组，每条含 `description` 与 `manipulators`，`from` 用 `consumer_key_code`（如 `play_or_pause`、`volume_increment`），`to` 用 `key_code` + `modifiers`。
- `swallow_original`：`true` 时吞掉原始媒体行为（推荐，否则调音量/播放仍会同时发生）。
- `title`：菜单栏提示标题。

调试日志（含权限状态、每次按键的来源与命中规则）写在：

```
~/.config/echokey/debug.log
```

出问题时先看这个文件，再用「按键测试…」核对通道。

## 菜单栏

点图标可：启用/停用映射、开关「拦截原始按键」、打开设置、打开按键测试、设置开机自启动、退出。

## 授权说明

本仓库为个人工具，代码仅作参考与自用，**目前未附带开源许可文件**（即默认保留所有权利）。若需要以 MIT 等许可开放，请自行添加 `LICENSE` 文件或在 issue 中说明。

系统权限方面：EchoKey 不联网、不收集、不上传任何数据，事件只在本地处理；配置与日志均保存在本机 `~/.config/echokey/`。
