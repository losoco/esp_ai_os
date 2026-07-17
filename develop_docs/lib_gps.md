# lib_gps

NMEA-0183 GPS 解析器，纯 Lua 实现，通过 UART 轮询获取定位数据。

## 硬件配置

| 参数 | 值 |
|------|-----|
| 接口 | UART |
| TX / RX | GPIO38 / GPIO37 (UART0) |
| 波特率 | 9600 |
| 电源 | TCA9555 P0-0 (高有效) |

## API

### `gps.new(opts) -> handle`

创建 GPS 解析器实例。

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `opts.port` | integer | - | UART 端口号 (必填) |
| `opts.tx` | integer | - | TX GPIO 引脚 (必填) |
| `opts.rx` | integer | - | RX GPIO 引脚 (必填) |
| `opts.baud` | integer | 9600 | 波特率 |
| `opts.bus` | userdata | - | 已有 UART 句柄，传入则跳过内部 `uart.new` |

```lua
local gps = require("lib_gps")

-- 方式一：内部创建 UART
local g = gps.new({ port = 0, tx = 38, rx = 37, baud = 9600 })

-- 方式二：复用已有 UART 句柄
local bus = uart.new(0, 38, 37, 9600)
local g = gps.new({ bus = bus })
```

### `handle:poll() -> int`

轮询 UART RX 缓冲区，解析完整的 NMEA 句子。返回本次处理的行数（0 = 无数据）。

调用方应周期性调用此方法（如每秒一次），持续排空 UART 缓冲区。

```lua
while running do
    local lines = g:poll()
    if lines > 0 then
        local s = g:get_snapshot()
        -- 处理快照...
    end
    delay.delay_ms(1000)
end
```

### `handle:get_snapshot() -> table`

返回当前 GPS 状态快照。数据在 `poll()` 时自动更新，可随时读取。

| 字段 | 类型 | 说明 |
|------|------|------|
| `fix_valid` | bool | 是否已定位 |
| `fix_quality` | int | 定位质量: 0=无, 1=GPS, 2=DGPS |
| `latitude_deg` | float | 纬度 (十进制度, 北正南负) |
| `longitude_deg` | float | 经度 (十进制度, 东正西负) |
| `altitude_m` | float | 海拔 (米) |
| `speed_kmh` | float | 速度 (km/h) |
| `satellites_used` | int | 定位使用的卫星数 |
| `satellites_view` | int | 可视卫星总数 (多星座累加) |
| `hdop` | float | 水平精度因子 (越小越好, <1 优秀) |
| `utc_time` | string | UTC 时间 "HH:MM:SS" |
| `utc_date` | string | UTC 日期 "YYYY-MM-DD" |
| `sentence_count` | int | 累计解析的句子数 |
| `bytes_received` | int | 累计接收字节数 |

### `handle:close()`

释放 UART 资源。如果 `bus` 由内部创建则关闭 UART，复用外部句柄则不关闭。

## NMEA 协议

### 句子结构

```
$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n
^      ^                                                ^  ^
起始符  talker+句型                                       *  校验和
```

- 起始符 `$`，结束符 `\r\n`
- 校验和: `$` 与 `*` 之间所有字节 XOR，结果与 `*` 后两位十六进制比较
- 字段以逗号分隔，空字段（`,,`）合法

### 支持的句型

#### GGA - 位置与定位质量

```
$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47
       UTC   纬度    N/S 经度    E/W 质量 数量 HDOP 海拔
```

- `fix_quality`: 0=无定位, 1=GPS, 2=DGPS
- `satellites_used`: 参与定位的卫星数
- 坐标格式: 纬度 `DDMM.mmmm`，经度 `DDDMM.mmmm`

#### RMC - 速度与日期

```
$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
       UTC   状态 纬度  N/S 经度  E/W 节速  航向  日期
```

- 状态: `A`=有效定位, `V`=无效
- 速度: 节 (knots)，内部转换为 km/h (×1.852)

#### GSV - 可视卫星

```
$GPGSV,2,1,08,01,40,083,46,02,17,308,41,...
       总条数 序号 可视数 PRN 仰角 方位角 信噪比
```

- GSV 句子按星座分组输出，一条 GSV 最多描述 4 颗卫星
- 可视卫星数取每条 GSV 的第 4 字段
- 多星座时各 talker 独立计数后求和

### Talker 标识

| 前缀 | 星座系统 |
|------|----------|
| `GP` | GPS (美国) |
| `GL` | GLONASS (俄罗斯) |
| `GA` | Galileo (欧洲) |
| `BD` | BeiDou (中国) |
| `GN` | 多星座混合 |

## 解析器实现要点

### 校验和验证

`$` 与 `*` 之间字节逐个 XOR，与 `*` 后两位十六进制比较。校验失败则丢弃该行。

### 坐标转换

`DDMM.mmmm` → 度 + 分/60 → 十进制度数：

```
4807.038 → 48 + 07.038/60 = 48.1173°
01131.000 → 11 + 31.000/60 = 11.5167°
```

### 空字段处理

NMEA 句子中空字段（`,,`）合法。使用 `gmatch("([^,]*),")` 而非 `gmatch("[^,]+")` 保留空字段，确保后续字段索引正确。

### GSV 多星座累加

`_sats_per_talker` 表按 talker 记录各星座最新可视卫星数，`satellites_view` 为所有星座之和。

### 轮询防洪泛

单次 `poll()` 最多处理 100 行，防止 UART 数据堆积导致 Lua 任务长时间阻塞。

## 使用示例

### 基本定位

```lua
local gps = require("lib_gps")
local delay = require("delay")

local g = gps.new({ port = 0, tx = 38, rx = 37, baud = 9600 })

for i = 1, 30 do
    g:poll()
    local s = g:get_snapshot()
    if s.fix_valid then
        print(string.format("定位: %.6f, %.6f 海拔=%.1fm 速度=%.1fkm/h",
            s.latitude_deg, s.longitude_deg, s.altitude_m, s.speed_kmh))
    else
        print(string.format("搜索中... 可视卫星=%d", s.satellites_view))
    end
    delay.delay_ms(1000)
end

g:close()
```

### 配合 IO 扩展器控制电源

```lua
local gps = require("lib_gps")
local i2c = require("i2c")
local delay = require("delay")

-- 打开 GPS 电源 (TCA9555 P0-0)
local bus = i2c.wrap(1)
local expander = bus:device(0x20)
local cur = expander:read(1, 0x02)
expander:write_byte(string.byte(cur, 1) | 0x01, 0x02)
delay.delay_ms(500)

-- 使用 GPS
local g = gps.new({ port = 0, tx = 38, rx = 37, baud = 9600 })
-- ... 轮询读取 ...

-- 关闭 GPS 电源
g:close()
cur = expander:read(1, 0x02)
expander:write_byte(string.byte(cur, 1) & ~0x01, 0x02)
```

### 后台持续监控

```lua
local gps = require("lib_gps")
local delay = require("delay")

local g = gps.new({ port = 0, tx = 38, rx = 37, baud = 9600 })

while true do
    g:poll()
    local s = g:get_snapshot()
    if s.sentence_count > 0 then
        -- 写入日志或上报数据
        print(string.format("fix=%s sats=%d/%d hdop=%.1f",
            s.fix_valid and "YES" or "NO",
            s.satellites_used, s.satellites_view, s.hdop))
    end
    delay.delay_ms(2000)
end
```

## 测试

### 单元测试 (本地, 无需设备)

```bash
cd components/lua_modules/lua_module_gps
lua5.4 test/test_gps_nmea.lua
```

测试覆盖：GGA 位置解析、RMC 速度/日期、GSV 卫星数、坏校验和跳过、GLONASS talker。

### 设备端测试

```bash
# 上传并运行设备端测试 (30s, 自动控制电源)
esp-claw-cli push test/gps_device_test.lua /inbox/gps_device_test.lua
esp-claw-cli run /inbox/gps_device_test.lua --no-upload --timeout-ms 0 --wait 35

# 下载日志
esp-claw-cli pull /inbox/gps_test.log /tmp/gps_test.log
```

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `sats=0/0` `bytes=0` | UART 未收到数据 | 检查 TX/RX 接线、波特率、GPS 电源 |
| `sats=0/0` `bytes>0` | 信号弱 | 移至窗边或户外，冷启动需 30s-2min |
| `time=` 空 | 未从卫星同步时间 | 正常现象，定位成功后自动填充 |
| `hdop=25.5` | 无定位时的无效值 | 不代表实际精度，定位后才有意义 |
| 数据间断 | poll 间隔过长 | 建议 poll 间隔 ≤ 2s，避免 UART 缓冲区溢出 |
