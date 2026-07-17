# ESP AI OS

**ESP AI OS** 是构建在乐鑫芯片上的嵌入式操作系统层，将 ESP-Claw AI Agent 框架转变为一个完整的应用平台。它提供触控驱动的应用启动器、显示服务、应用生命周期管理和硬件抽象层 — 将裸机 IoT 设备变成掌上 AI 计算机。

旗舰平台为 **ESP32-P4**（双核 RISC-V，720×720 MIPI-DSI，32 MB PSRAM），同时支持 ESP32-S3、ESP32-C5 和 ESP32-S31。

---

## 愿景

> **让乐鑫芯片成为 AI 原生的应用平台。**

ESP AI OS 位于 ESP-Claw AI Agent 运行时与硬件之间，提供了将一系列 Lua 脚本串联为统一用户体验的关键层：

```
┌─────────────────────────────────────────────────────────────────┐
│                        应用层                                    │
│   游戏 │ 传感器 │ 相机 │ 水平仪 │ 天气 │ 用户应用                 │
├─────────────────────────────────────────────────────────────────┤
│                     ESP AI OS                                    │
│   启动器 │ 显示服务 │ 应用生命周期 │ 硬件抽象                      │
├─────────────────────────────────────────────────────────────────┤
│                  ESP-Claw AI Runtime                              │
│   Agent Core │ 事件路由 │ 记忆 │ 技能 │ 能力                      │
├─────────────────────────────────────────────────────────────────┤
│                    ESP-IDF + 硬件                                 │
│   ESP32-P4 │ MIPI-DSI │ PSRAM │ Flash │ 触控 │ 传感器             │
└─────────────────────────────────────────────────────────────────┘
```

---

## OS 层对照

| OS 组件      | Android 等价物  | ESP AI OS 实现                                        |
| ------------ | --------------- | ----------------------------------------------------- |
| 主屏幕       | Launcher        | `launcher.lua` — 桌面网格、应用抽屉、最近使用      |
| 显示服务     | SurfaceFlinger  | `display_arbiter` — 按应用独占显示所有权           |
| 窗口管理     | WindowManager   | `lua_lvgl_runtime` — LVGL 9 渲染器 + DSI 双缓冲    |
| 应用生命周期 | ActivityManager | `boot_launcher.c` — 自动启动、自动恢复、上滑杀进程 |
| 应用包       | APK             | Lua 脚本 +`manifest.json`（schema 校验）            |
| 硬件总线     | HIDL/HAL        | `board_manager` — 统一外设发现与访问               |
| 显示驱动     | DRM/KMS         | `esp_lcd_panel`（DSI/SPI/RGB）+ 各面板厂驱动        |
| 输入         | InputFlinger    | LVGL indev + 触摸手势检测（上滑 = 杀应用）            |
| 文件系统     | VFS             | `/system`（只读固件）+ `/sdcard`（可写数据）      |

---

## 应用生命周期

每个应用是一个包含 `manifest.json` 的 Lua 脚本。同一时间只有一个应用在前台运行 — 独占模式保证嵌入式设备上硬件访问的确定性。

```
用户点击 Launch
      │
      ▼
  launcher 释放 LVGL，归还显示所有权
      │
      ▼
  thread.start(app) → app 独占显示 + 外设
      │
      ▼
  launcher 完全退出（零资源占用）
      │
      ▼
  app 运行直到自行退出或上滑被杀
      │
      ▼
  boot_launcher 检测到无运行脚本 → 自动重启 launcher
```

---

## 核心特性

- **触控应用平台** — 4×3 桌面网格 + 翻页、可滚动应用抽屉、应用详情、最近使用历史
- **全屏 DSI 渲染** — `LV_DISPLAY_RENDER_MODE_FULL` 双缓冲，1 次 flush/帧，~2 MB PSRAM，720×720 面板零撕裂
- **AI Agent 运行时** — 通过 IM 频道对话编程、事件驱动 Agent 循环、结构化记忆、MCP 客户端/服务端
- **清新浅色主题** — 白色卡片 + 蓝色点缀，为 3.95 寸方形屏优化
- **硬件抽象** — Board Manager 自动发现外设；应用通过 `board_manager.get_display_lcd_params()` 访问硬件，无需硬编码引脚号
- **无线开发** — 将 `launcher.lua` 或应用脚本推送到 `/sdcard`，无需重新烧录固件

---

## 性能指标（ESP32-P4 + MIPI-DSI）

| 指标            | 值                                                               |
| --------------- | ---------------------------------------------------------------- |
| 显示分辨率      | 720 × 720，24 bpp                                               |
| LVGL 渲染模式   | `FULL`（双缓冲）                                               |
| 显示缓冲        | 2 × 720 × 720 × 2 =**2 MB PSRAM**                       |
| 每帧 flush 次数 | **1**                                                      |
| DMA 流水线      | 渲染 buf1 同时 DSI 传输 buf2                                     |
| 面板唤醒        | 仅 re-init 时发送 `DISPON (0x29)`；永不发送 `DISPOFF (0x28)` |
| 背光            | 板级原生 LEDC PWM（非 DCS 指令）                                 |

---

## 快速开始

```bash
# 安装 ESP-IDF v5.5.4
git clone -b v5.5.4 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32p4 && . ./export.sh

# 为 Metalio Claw4 构建（ESP32-P4 + MIPI-DSI）
cd application/edge_agent
idf.py bmgr -c ./boards -b metalio_claw_4
idf.py build
idf.py flash monitor
```

---

## 开发

```bash
# 推送 launcher 到设备进行实时开发
python tools/esp-claw-cli/esp-claw-cli.py push \
  application/edge_agent/fatfs_image/system/launcher.lua \
  /launcher.lua

# 设备将自动加载 SD 卡上的 launcher，覆盖内置版本
```

---

## 项目结构

```
application/edge_agent/
├── boards/CloudZao/metalio_claw_4/    # ESP32-P4 旗舰板
│   ├── components/esp_lcd_nv3051f/    # NV3051F DSI 面板驱动
│   └── setup_device.c                 # 板级初始化、面板时序
├── fatfs_image/system/launcher.lua    # ESP AI OS 主屏幕
├── fatfs_image/system/apps/           # 内置系统应用
components/
├── common/boot_launcher/              # 应用生命周期管理器
│   └── boot_launcher.c                # 自动启动、重启、上滑杀进程
├── lua_modules/
│   ├── lua_module_lvgl/               # LVGL 9 + DSI 双缓冲
│   │   └── src/lua_lvgl_runtime.c     # 显示服务、flush 流水线
│   ├── lua_module_display/            # 显示 HAL（帧缓冲管理）
│   ├── lua_module_board_manager/      # 外设发现与访问
│   └── lua_module_storage/            # /system + /sdcard VFS
├── claw_modules/
│   ├── claw_core/                     # AI Agent 运行时
│   ├── claw_event_router/             # 声明式事件路由
│   ├── claw_memory/                   # 会话与档案记忆
│   └── claw_skill/                    # 技能管理
└── claw_capabilities/                 # 具体 Agent 能力
```

---



<pre class="vditor-reset" placeholder="" contenteditable="true" spellcheck="false"><p data-block="0"><br class="Apple-interchange-newline"/><img src="https://file+.vscode-resource.vscode-cdn.net/Users/ryan/workspace/esp-claw_origin/image/README/1784258401647.png" alt="1784258401647"/></p><p data-block="0"><img src="https://file+.vscode-resource.vscode-cdn.net/Users/ryan/workspace/esp-claw_origin/image/README/1784257966824.png" alt="1784257966824"/></p><p data-block="0"><img src="https://file+.vscode-resource.vscode-cdn.net/Users/ryan/workspace/esp-claw_origin/image/README/1784257979887.png" alt="1784257979887"/></p></pre>


## License

Apache-2.0 协议。详见 [LICENSE](./LICENSE)。

基于 Espressif [ESP-Claw](https://github.com/espressif/esp-claw) 构建。灵感源自 [OpenClaw](https://github.com/openclaw/openclaw)。
