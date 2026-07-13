# Metalio Claw4 移植开发计划

> 源项目: [CloudZao/MetalioClaw4](https://github.com/CloudZao/MetalioClaw4) (基于 xiaozhi-esp32 框架)
> 目标项目: ESP-Claw (自研 AI Agent 固件)
> 主控: ESP32-P4 + ESP32-C5 协处理器

---

## 一、硬件概览

| 芯片 | 角色 | 接口 |
|------|------|------|
| ESP32-P4 | 主 MCU (双核 RISC-V 480MHz, 32MB Flash, 32MB PSRAM) | UI / 音视频 / 相机 / GPS / SD卡 |
| ESP32-C5 | WiFi 协处理器 (2.4/5GHz) | SDIO Slot 1, 4-bit, 40MHz |
| NT26 | 4G LTE 蜂窝模组 | UART + MRDY/SRDY 流控 |

### I2C 总线设备 (SDA=GPIO7, SCL=GPIO8, Port 1)

| 设备 | 芯片 | I2C 地址 | 状态 |
|------|------|----------|------|
| 触摸控制器 | GT911 | 0x5D / 0x14 | 已移植 |
| IO 扩展器 | TCA9555 | 0x20 | 已移植 |
| 电量计 | BQ27220 | 0x55 | 已移植 (Lua 驱动, lib_fuel_gauge) |
| 无线充电 | NU1680 | 0x60 | 已移植 (Lua 驱动, lib_nu1680) |
| 磁力计 | QMC6309 | 0x7C | 已移植 (C 后端, lua_module_magnetometer) |
| 加速度计 | SC7A20H | 0x19 | 已移植 (Lua 驱动, lib_sc7a20h) |
| 摄像头 SCCB | OV2710 | 0x36 | 已移植 (Board Manager) |

### GPIO 引脚总览

| 功能 | GPIO | 备注 |
|------|------|------|
| I2C SDA / SCL | 7 / 8 | Port 1 |
| LCD 复位 (共享相机) | 3 | |
| LCD 背光 PWM | 52 | LEDC TIMER_0 / CHANNEL_0 |
| 振动马达 | 22 | LEDC TIMER_1 / CHANNEL_1 |
| I2S BCLK / WS / DOUT / DIN | 12 / 10 / 9 / 11 | Port 0 |
| SDMMC CLK / CMD / D0-D3 | 43 / 44 / 39-42 | Slot 0, 4-bit |
| SDIO (C5) CMD / CLK / D0-D3 | 50 / 51 / 49 / 34 / 31 / 53 | Slot 1 |
| SDIO C5 RESET | 54 | 高有效 |
| 蓝牙音频 UART TX / RX | 26 / 27 | UART2, 115200 |
| NT26 UART TX / RX | 28 / 29 | |
| NT26 MRDY / SRDY | 13 / 4 | 流控 |
| GPS UART TX / RX | 38 / 37 | UART0, 9600 |
| 相机 XCLK | 32 | 24MHz |
| Boot 按键 | 35 | |

### TCA9555 IO 扩展器引脚映射 (I2C 0x20)

| 引脚 | 方向 | 功能 | 初始电平 |
|------|------|------|----------|
| P0-0 | OUT | GPS 电源 | 高 (开) |
| P0-1 | OUT | PA 切换 (0=4G, 1=WIFI) | 高 (WIFI) |
| P0-2 | OUT | 相机 PWDN (低=通电) | 高 (断电) |
| P0-3 | OUT | SD 卡电源 (低=通电) | 低 (开) |
| P0-4 | OUT | 软件关机脉冲 | 低 |
| P0-5 | IN | 电源按键状态 | - |
| P0-6 | OUT | 蓝牙芯片电源 | 高 (开) |
| P0-7 | OUT | 4G 模组复位 | 高 (释放) |
| P1-0 | OUT | 音频功放使能 | 高 (开) |
| P1-1 | IN | 加速度计中断 | - |
| P1-2 | IN | USB 插入检测 | - |
| P1-3 | IN | 无线充电检测 | - |

---

## 二、已完成工作

### 2.1 板卡框架

- [x] `board_info.yaml` - 板卡元数据
- [x] `board_peripherals.yaml` - 外设定义 (I2C, I2S, LDO, DSI, LEDC x2)
- [x] `board_devices.yaml` - 设备定义 (7 个设备)
- [x] `sdkconfig.defaults.board` - SDK 配置
- [x] `setup_device.c` - 工厂函数

### 2.2 已移植设备

| 设备 | 状态 | 说明 |
|------|------|------|
| TCA9555 IO 扩展器 | 已工作 | I2C 0x20, 8 路输出 + 4 路输入 |
| SD 卡 (SDMMC Slot 0) | 已工作 | 4-bit, LDO 由 ESP-Hosted 管理 |
| NV3051F 显示屏 | 已工作 | 720x720, MIPI-DSI 2-lane, 36MHz DPI |
| GT911 触摸 | 已工作 | 720x720, I2C 地址自动探测 |
| 背光 | 已工作 | LEDC TIMER_0 / CHANNEL_0, 25kHz, 10-bit |
| 振动马达 | 已工作 | LEDC TIMER_1 / CHANNEL_1, 5kHz, 10-bit, default_percent=0 |
| 摄像头 (OV2710) | 已工作 | MIPI-CSI, XCLK=GPIO32@24MHz, PWDN=TCA9555 P0-2(low=powered) |
| WiFi (ESP32-C5) | 已工作 | ESP-Hosted SDIO, LDO chan 4 独立管理 |
| NV3051F LCD 驱动 | 已移植 | `components/esp_lcd_nv3051f/` |
| 蓝牙模块 | 已工作 | UART2 (TX=26, RX=27), I2S 从模式, AT 命令 Mode 1 初始化 |
| 蓝牙音频 Lua 模块 | 已完成 | `lua_module_bt_audio`，支持 local/pair/music 三种模式切换 |
| BQ27220 电量计 | 已工作 | I2C 0x55, 纯 Lua 驱动 `lib_fuel_gauge`, 电压/电流/SOC 读取 |
| SC7A20H 加速度计 | 已工作 | I2C 0x19, 纯 Lua 驱动 `lib_sc7a20h`, LIS2DH12 兼容, ±2g/100Hz |
| NU1680 无线充电 | 已工作 | I2C 0x60, 纯 Lua 驱动 `lib_nu1680`, 过流保护电流限制 + 温度保护 |
| QMC6309 磁力计 | 已工作 | I2C 0x7C, C 后端 `lua_module_magnetometer`, 硬铁校准 API |
| GPS | 已工作 | UART0 (TX=38, RX=37, 9600), 纯 Lua 驱动 `lib_gps`, NMEA 解析 (GGA/RMC/GSV) |
| NT26 4G | 已工作 | UART1 (TX=28, RX=29, 2M), 纯 Lua AT 命令驱动 `lib_nt26`, 信号/IMEI/ICCID/基站查询 |

### 2.3 已解决的关键问题

| 问题 | 根因 | 解决方案 |
|------|------|----------|
| SDIO C5 通信失败 | P4 默认 SDIO 引脚与实际 PCB 不同 | 设置 `ESP_HOSTED_PRIV_SDIO_PIN_*_SLOT_1` |
| LDO 通道冲突 | SD 卡和 C5 共享 LDO chan 4, SD 卡释放后 C5 断电 | 启用 `ESP_HOSTED_SD_PWR_CTRL_LDO_INTERNAL_IO`, SD 卡 `ldo_chan_id: -1` |
| 振动马达一直转 | `dev_ledc_ctrl` 默认 `default_percent=100` | 显式设置 `default_percent: 0` |
| 音频 I2S 时钟错误 | I2S 配置为主模式, 但蓝牙芯片需要提供 BCLK/WS | 修改 `board_peripherals.yaml` I2S role 为 `slave` |
| 蓝牙模块未初始化 | 缺少蓝牙模块 UART 通信初始化 | 添加 `bt_module` 自定义设备 + `setup_device.c` UART2 初始化 |
| BT 模块不提供 I2S 时钟 | 蓝牙芯片上电后未收到 AT 命令, 未进入接收模式 | `setup_device.c` 添加 `bt_module_mode_init_task` 发送 `AT+RX=2` (700ms) `AT+MODE=1` |
| `esp-claw.local` 无法访问 | mDNS 服务未初始化 | `main.c` 添加 `mdns_init()` + `mdns_hostname_set("esp-claw")` |
| 摄像头初始化失败 `ESP_ERR_NOT_FOUND` | 缺少 XCLK 时钟配置 + CAM_PWDN 初始电平错误(高=断电) | 添加 XCLK 配置(GPIO32@24MHz) + 修改 CAM_PWDN 初始电平为低(通电) |

---

## 三、待移植设备

按优先级和难度排列。

### P0 - Lua 驱动可覆盖 (低难度, 通过 Lua I2C/UART 驱动即可使用)

| 设备 | 芯片 | 接口 | I2C/UART | 移植方式 | 备注 |
|------|------|------|----------|----------|------|
| 电量计 | BQ27220 | I2C | 0x55 | Lua I2C 驱动 | 电压/电流读取, 60 点滑动平均, 3.3V=0% / 4.2V=100% |
| 无线充电 | NU1680 | I2C | 0x60 | Lua I2C 驱动 | 已完成, 寄存器 0x1E 限流配置, 0x15 温度保护, 500ms 探测 |
| 磁力计 | QMC6309 | I2C | 0x7C | C 后端驱动 | Chip ID 0x00=0x90, X/Y/Z 数据 0x01-0x06 |
| 加速度计 | SC7A20H | I2C | 0x19 | Lua I2C 驱动 | LIS2DH12 兼容, CTRL_REG1=0x20, CTRL_REG4=0x23, 中断=P1-1 |

这四个设备均可通过 ESP-Claw 现有的 `lua_driver_i2c` 模块直接驱动, 无需修改 C 层代码。

#### 3.1 BQ27220 电量计

```
寄存器:
  Voltage: 0x08 (uint16, mV)
  Current: 0x0C (int16, mA, +充电/-放电)

逻辑:
  - 充放电判定: current > +5mA = 充电, < -5mA = 放电
  - 电量计算: 电压线性插值 3.3V=0%, 4.2V=100%
  - 60 点滑动平均滤波
```

#### 3.2 NU1680 无线充电

```
寄存器:
  0x1E (MTP_ILIM_SET): 低 3 位 = 过流保护限流, 写 0x00 = 1.4A
  0x15: 温度保护, 写 0x00 关闭

逻辑:
  - 独立 task 每 500ms 探测 I2C 0x60 是否在线
  - 在线时自动初始化寄存器

**已完成**: 纯 Lua 驱动 (`lib_nu1680`)，支持 `configure` / `set_current_limit` / `get_current_limit`
  + 闭环监控: `nu1680_autoconf.lua` 500ms 轮询 I2C 0x60，适配器接入自动配置 + 屏幕通知，
    通过 BQ27220 电流检测充满状态
```

#### 3.3 QMC6309 磁力计

```
寄存器:
  0x00: Chip ID (期望 0x90)
  0x01-0x06: X/Y/Z 数据 (int16, little-endian)
  0x0A: CR1 (配置寄存器 1)
  0x0B: CR2 (配置寄存器 2)

初始化序列 (每步 >=20ms):
  suspend -> normal -> suspend -> continuous (CR2 写入 SET/RESET)

**已完成**: C 后端驱动 (`lua_module_magnetometer`)，提供硬铁校准 API (`calibration_reset/add_sample/finish`)
```

#### 3.4 SC7A20H 加速度计

```
寄存器 (LIS2DH12 兼容):
  0x20: CTRL_REG1 = 0x57 (100Hz ODR, Z/Y/X enable)
  0x23: CTRL_REG4 = 0x88 (BDU=1, +-2g, HR mode)
  0x28: OUT_X_L (多字节读, MSB 置 1 自增)

中断: TCA9555 P1-1 (ACCEL_INT, 低有效)
```

### P1 - 需要 C 层支持 (中难度)

| 设备 | 芯片 | 接口 | 引脚 | 移植方式 | 备注 |
|------|------|------|------|----------|------|
| 蓝牙音频 | BTAudioCodec | UART2 + I2S | TX=26, RX=27 | Lua 模块 | 115200 baud, AT 命令, 三模式切换 (`lua_module_bt_audio` 已完成) |

#### 3.5 蓝牙音频编解码器

```
UART: TX=GPIO26, RX=GPIO27, UART2, 115200 baud
I2S: BCLK=12, WS=10, DOUT=9, DIN=11 (I2S_NUM_0, slave 模式)
电源: TCA9555 P0-6 (BT_POWER)

三种模式 (AT 命令切换):
  1. 日常语音交互 (默认) -- 开机自动发送 AT+RX=2 + AT+MODE=1
  2. 连接蓝牙耳机/音箱   -- AT+TX=1 + AT+MODE=2
  3. 手机 -> 设备蓝牙音箱播放 -- AT+RX=1 + AT+MODE=3
```

**已完成**:
- `lua_module_bt_audio` Lua 模块支持三种模式切换
- 命令行: `lua --run --path /system/skills/bt_audio/scripts/switch_mode.lua --args-json {"mode":"local"}`
- Mode 1 开机自动初始化 (`setup_device.c` 中 `bt_module_mode_init_task`)
- 音频数据通路 (I2S slave -> esp_codec_dev -> lua_module_audio) 已就绪

### P2 - 需要完整协议栈 (高难度)

> 4G LTE 模组基础 AT 命令接口已通过纯 Lua 驱动 `lib_nt26` 完成 (UART1, 2M baud)。
> 完整 PPP/网络栈实现仍需 C 层支持，当前可通过 Lua AT 命令完成信号查询、IMEI/ICCID 读取、基站定位等基础功能。
>
> | 功能 | 状态 | 说明 |
> |------|------|------|
> | AT 命令通信 | 已完成 | `lib_nt26` 纯 Lua |
> | 信号强度 / IMEI / ICCID | 已完成 | `lib_nt26` |
> | 基站定位 (ECBCINFO) | 已完成 | `lib_nt26` |
> | 拨号 / 挂断 | 已完成 | `lib_nt26` |
> | PPP 网络拨号 | 待实现 | 需要 C 层 `esp_modem` 或自定义组件 |
> | WiFi/4G 双网络切换 | 待实现 | 需要 `DualNetworkBoard` 封装 |

---

## 四、开发路线图

### 阶段一: 基础验证 (已完成)

- [x] 板卡框架搭建
- [x] 显示 + 触摸 + 背光
- [x] SD 卡存储
- [x] WiFi (ESP32-C5 via SDIO)
- [x] 振动马达
- [x] 摄像头配置
- [x] NV3051F LCD 驱动移植

### 阶段二: 传感器驱动 (Lua I2C)

- [x] BQ27220 电量计 Lua 驱动
- [x] NU1680 无线充电 Lua 驱动
- [x] QMC6309 磁力计 C 后端驱动
- [x] SC7A20H 加速度计 Lua 驱动

### 阶段三: 通信外设

- [x] GPS Lua UART 驱动 + NMEA 解析 (`lib_gps`)
- [x] 蓝牙音频 Lua 模块 (AT 命令 + I2S)
- [x] NT26 4G 模组基础 AT 命令接口 (`lib_nt26`)

### 阶段四: 系统集成

- [ ] 音频通路集成 (I2S + 蓝牙音频编解码器)
- [ ] 电源管理 (电量计 + 无线充电 + 软件关机)
- [ ] NT26 PPP 网络拨号 (C 层 `esp_modem`)
- [ ] 双网络切换 (WiFi / 4G)
- [ ] 摄像头功能验证 (MIPI-CSI + OV2710)

---

## 五、构建命令

```bash
cd application/edge_agent
idf.py bmgr -c ./boards -b metalio_claw_4
idf.py build
idf.py -p PORT flash monitor
```

---

## 六、调试方法

### 6.1 Lua 脚本远程执行

```bash
# 单行代码执行
esp-claw-cli exec "print('hello')"

# 上传并运行脚本
esp-claw-cli push test.lua /inbox/test.lua
esp-claw-cli run /inbox/test.lua --no-upload --timeout-ms 0 --wait 10

# 查看作业列表
esp-claw-cli jobs
# 停止作业
esp-claw-cli stop <job_id>

# 从设备下载文件（如日志）
esp-claw-cli pull /inbox/wx_test.log /tmp/wx_test.log
```

### 6.2 I2C 设备探测

```lua
-- 复用系统已创建的 I2C 总线（新固件，推荐）
local bus = i2c.wrap(1)

-- 或创建新总线（引脚必须匹配 board_peripherals.yaml）
local bus = i2c.new(1, 7, 8, 400000)

-- 创建设备句柄
local dev = bus:device(0x60)

-- 读取寄存器（返回 Lua string）
local data = dev:read(2, 0x08)  -- 读 2 字节从寄存器 0x08

-- 写入寄存器
dev:write(string.char(0x00), 0x1E)  -- 向 0x1E 写入 0x00

-- 安全探测（设备可能不在线）
if pcall(function() dev:read(1, 0x00) end) then
    print("device present")
else
    print("device not found")
end
```

### 6.3 通过文件获取完整日志

作业状态 API 的 `recent_log` 只显示首行，输出会被截断。获取完整日志的方法：

```lua
-- 在脚本中将日志写入文件
local f = io.open("/sdcard/inbox/wx_test.log", "w")
f:write("...")
f:close()

-- 在主机上下载
esp-claw-cli pull /inbox/wx_test.log /tmp/wx_test.log
cat /tmp/wx_test.log
```

### 6.4 LEDC 振动马达控制

```lua
local bm = require("board_manager")

-- 振动 200ms
bm.set_ledc_duty("vibration_motor", 80)  -- 80% 占空比
delay.delay_ms(200)
bm.set_ledc_duty("vibration_motor", 0)   -- 停止
```

### 6.5 查看作业详细状态

```bash
curl -s http://192.168.8.100/api/files/run/<job_id> | python3 -m json.tool
```

关键字段：
- `status`: running / completed / failed / stopped
- `runtime_s`: 已运行秒数
- `log_size`: 输出日志字节数（上限 4096）
- `recent_log`: 压缩视图（只显示一行）

### 6.6 已知问题

| 问题 | 现象 | 原因 | 解决 |
|------|------|------|------|
| `i2c.new()` 在后台脚本中 I2C 操作失败 | 设备探测返回 false，但单独 exec 成功 | 旧版 I2C 驱动 API 与板级管理器冲突 | 使用 `i2c.wrap(port)` |
| `gpio.new_out(22)` 控制振动马达失败 | `unknown error` | GPIO22 已被 LEDC 占用 | 使用 `bm.set_ledc_duty("vibration_motor", pct)` |
| 作业输出日志被截断 | `recent_log` 只显示首行 | `cap_lua` 输出缓冲 4KB 且 `recent_log` 只取第一行 | 写入文件后用 `pull` 下载 |
| NU1680 探测延迟 | 前 4 次探测失败，第 5 次成功 | 芯片上线需 ~2s | 后台轮询自动重试 |

### 6.7 无线充电闭环测试流程

```bash
# 1. 上传并启动后台监控
esp-claw-cli push nu1680_autoconf.lua /inbox/nu1680_autoconf.lua
esp-claw-cli run /inbox/nu1680_autoconf.lua --no-upload --timeout-ms 0

# 2. 放上充电器 → 应感到 400ms 长振动
# 3. 取下充电器 → 应感到 2 次 100ms 短振动

# 4. 查看是否在运行
esp-claw-cli jobs | grep nu1680

# 5. 停止
esp-claw-cli stop <job_id>
```

---

## 七、参考文件

| 文件 | 用途 |
|------|------|
| [config.h](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/boards/metalio-claw-4/config.h) | 原始项目 GPIO 引脚定义 |
| [metalio-claw-4.cc](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/boards/metalio-claw-4/metalio-claw-4.cc) | 原始项目板卡初始化代码 |
| [backlight.cc](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/boards/common/backlight.cc) | 背光 LEDC 配置参考 |
| [vibrate_screen.cc](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/display/screen/vibrate_screen/vibrate_screen.cc) | 振动马达 LEDC 配置参考 |
| [bq27220_gauge.cc](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/boards/common/bq27220_gauge.cc) | 电量计驱动参考 |
| [gps_service.cc](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/boards/common/gps_service.cc) | GPS 驱动参考 |
| [bt_audio_codec.cc](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/boards/common/bt_audio_codec.cc) | 蓝牙音频驱动参考 |
| [nt26_board.cc](file:///Users/ryan/workspace/esp32p4/MetalioClaw4_CloudZao/MetalioClaw4/main/boards/common/nt26_board.cc) | 4G 模组驱动参考 |
