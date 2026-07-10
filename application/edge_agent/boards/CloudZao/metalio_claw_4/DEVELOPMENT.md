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
| 电量计 | BQ27220 | 0x55 | 待移植 |
| 无线充电 | NU1680 | 0x60 | 待移植 |
| 磁力计 | QMC6309 | 0x7C | 待移植 |
| 加速度计 | SC7A20H | 0x19 | 待移植 |
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
| 无线充电 | NU1680 | I2C | 0x60 | Lua I2C 驱动 | 寄存器 0x1E 限流配置, 0x15 温度保护, 500ms 探测 |
| 磁力计 | QMC6309 | I2C | 0x7C | Lua I2C 驱动 | Chip ID 0x00=0x90, X/Y/Z 数据 0x01-0x06 |
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
```

#### 3.3 QMC6309 磁力计

```
寄存器:
  0x00: Chip ID (期望 0x90)
  0x01-0x06: X/Y/Z 数据 (int16, little-endian)
  0x0A: CR1 (配置寄存器 1)
  0x0B: CR2 (配置寄存器 2)

初始化序列 (每步 >=10ms):
  suspend -> normal -> suspend -> continuous
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
| GPS | UART NMEA | UART | TX=38, RX=37 | Lua UART 驱动 | 9600 baud, NMEA-0183, 电源=TCA9555 P0-0 |
| 蓝牙音频 | BTAudioCodec | UART2 + I2S | TX=26, RX=27 | Lua 模块 | 115200 baud, AT 命令, 三模式切换 (`lua_module_bt_audio` 已完成) |

#### 3.5 GPS 模组

```
UART: TX=GPIO38, RX=GPIO37, 9600 baud, 8N1
电源: TCA9555 P0-0 (GPS_POWER, 高有效)
协议: NMEA-0183 (GGA / RMC / GSV)
多星座: GP / GN / GL / GA / BD
```

可通过 `lua_driver_uart` 模块驱动, 配合 Lua NMEA 解析脚本实现。

#### 3.6 蓝牙音频编解码器

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

| 设备 | 芯片 | 接口 | 引脚 | 移植方式 | 备注 |
|------|------|------|------|----------|------|
| 4G LTE 模组 | NT26 | UART + 流控 | TX=28, RX=29, MRDY=13, SRDY=4 | 自定义组件 | AT 命令, 拨号/挂断/基站定位, 复位=TCA9555 P0-7 |

#### 3.7 NT26 4G 模组

```
UART: TX=GPIO28, RX=GPIO29, MRDY=GPIO13, SRDY=GPIO4
复位: TCA9555 P0-7 (RST_4G, 高有效)

功能:
  - 拨号 (ATD) / 挂断 (ATH)
  - 基站定位 (AT+ECBCINFO)
  - WiFi 扫描定位 (AT+ECWIFISCAN)
  - CEREG 注册状态查询

封装: DualNetworkBoard (WiFi / 4G 切换)
```

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

- [ ] BQ27220 电量计 Lua 驱动
- [ ] NU1680 无线充电 Lua 驱动
- [ ] QMC6309 磁力计 Lua 驱动
- [ ] SC7A20H 加速度计 Lua 驱动

### 阶段三: 通信外设

- [ ] GPS Lua UART 驱动 + NMEA 解析
- [x] 蓝牙音频 Lua 模块 (AT 命令 + I2S)
- [ ] NT26 4G 模组 C 组件 (AT 命令 + 流控)

### 阶段四: 系统集成

- [ ] 音频通路集成 (I2S + 蓝牙音频编解码器)
- [ ] 电源管理 (电量计 + 无线充电 + 软件关机)
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

## 六、参考文件

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
