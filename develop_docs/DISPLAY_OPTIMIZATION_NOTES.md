# 屏显优化要点总结

本文记录从 ESP32-P4 / MIPI DSI 项目中总结出的显示优化经验，用于指导 ESP AI OS 后续屏显优化。

## 1. 优先保证显示生命周期稳定

屏幕硬件应按常驻设备处理，应用切换时不要频繁关闭 panel 或发送 `DISPOFF`。

推荐策略：

- panel 初始化后保持工作
- app 退出只释放 display owner
- `display_hal_destroy()` 用于释放内部锁、flush 状态和运行时资源，但不能阻止 `display_arbiter_release()`
- 背光控制走板级 PWM/LEDC，不用 DCS `DISPON/DISPOFF` 当作普通亮灭屏接口

关键原则：

```text
硬件显示保持稳定
应用生命周期只切换所有权
清理失败不能卡住 display owner
```

## 2. MIPI DSI 下不要只看 buffer 大小

FULL / PARTIAL / 双缓冲 / 三缓冲不是单独决定显示效果的因素。真正关键是：

```text
什么时候提交帧
什么时候认为 flush 完成
什么时候允许重写 buffer
panel 是否仍在扫描旧 buffer
```

如果 `flush_ready` 早于 panel 实际 refresh done，LVGL 可能提前复用 buffer，导致闪烁、撕裂或花屏。

## 3. 使用 VSYNC / refresh_done 管理 buffer 生命周期

稳定显示的核心是以 panel refresh done 作为 buffer 生命周期边界。

推荐状态模型：

```text
FREE        可写
RENDERING   正在渲染
READY       渲染完成，等待提交
PENDING     已提交，等待 panel 接管
DISPLAYING  panel 正在扫描
```

只有当 refresh done 发生后，上一帧显示 buffer 才能回到 `FREE`。

## 4. 双缓冲不一定够，三缓冲更稳

双缓冲在以下情况下容易出现撕裂或等待：

- render 时间接近一帧周期
- DSI DMA 正在扫描旧 buffer
- LVGL/应用提前重写 buffer
- UI 和网络/Lua 任务抢占导致提交时机不稳

ESP32-P4 + 32 MB PSRAM 可以考虑三缓冲：

```text
RGB565: 720 × 720 × 2 × 3 ≈ 3.1 MB
RGB888: 720 × 720 × 3 × 3 ≈ 4.7 MB
```

ESP AI OS 如果恢复 FULL 模式，优先考虑 VSYNC-aware 双/三缓冲，而不是只改 `LV_DISPLAY_RENDER_MODE_FULL`。

## 5. 首帧预填背景色，避免黑屏/垃圾帧

在打开背光前，应确保 framebuffer 已经有确定内容。

推荐流程：

```text
panel init
获取 framebuffer
填充背景色到所有 framebuffer
再打开背光
启动 UI/动画渲染
```

这样可以避免启动时看到黑屏、随机数据或 panel 初始化过渡帧。

## 6. 渲染和提交解耦

复杂动画或全屏刷新场景中，推荐拆分为两个任务：

```text
producer: 负责解码、缩放、绘制 UI/overlay
consumer: 负责按 VSYNC 节奏提交 framebuffer
```

consumer 应比 producer 优先级更高，避免错过 VSYNC。

对 LVGL 来说，不一定要完整照搬 producer/consumer 架构，但应尽量避免：

- LVGL render 阻塞 flush 提交
- flush callback 里做过多工作
- 低优先级任务影响显示提交时机

## 7. 提交帧要贴近 VSYNC

MIPI DPI/DSI 显示中，提交整帧最好贴近 VSYNC 边界。

注意：

- 不要消费过期的 VSYNC semaphore 后立刻提交
- 如果 VSYNC 信号已经太旧，应等待下一次 VSYNC
- 否则可能在当前扫描周期中段切换 buffer，引入撕裂

## 8. Cache coherency 必须明确

当 framebuffer / draw buffer 位于 PSRAM，且 DMA 或 PPA 会读取时，要确认 cache 同步策略。

可能需要：

```c
esp_cache_msync(buffer, size, ESP_CACHE_MSYNC_FLAG_DIR_C2M);
```

注意：

- CPU 写 framebuffer 后，DMA 读前需要 C2M 同步
- PPA driver 可能内部已处理 cache coherency，不要重复做无意义同步
- 多核 worker 写不同区域时，要有 memory barrier 和明确的 flush 范围

## 9. 缩放应优先考虑 PPA

ESP32-P4 有 PPA，适合做：

- 图片缩放
- 图片旋转
- RGB/BGR swap
- 背景区域填充
- 相册、动画、相机预览类 app 的全屏处理

Launcher 普通 UI 不一定需要 PPA，但图标缩放、图片预览、媒体应用可以考虑使用。

## 10. CPU 缩放优化点

如果必须 CPU 缩放，可参考：

- nearest-neighbor 放大时，重复目标行直接 `memcpy`
- 多个目标像素映射到同一个源像素时缓存源像素
- 上半屏/下半屏分 worker 并行处理
- 边框填充单独优化，避免逐像素慢循环

这些适用于图片/动画 app，不建议强行塞进普通 LVGL widget 路径。

## 11. 对 ESP AI OS 当前阶段的建议

短期优先级：

1. 保持 panel 常驻，不随 app 切换反复关屏
2. app 退出必须释放 display owner
3. `flush_ready` 尽量对齐 panel refresh done
4. 避免 FULL 模式配半屏 buffer
5. 首帧/返回 launcher 时预填稳定背景
6. 确认 PSRAM draw buffer 的 cache 同步

中期优化：

1. MIPI DSI 下实现真正的双/三缓冲策略
2. 对 FULL 模式加入 VSYNC-aware buffer 生命周期管理
3. 提高显示提交路径优先级，减少 Lua/网络任务干扰
4. 图片/媒体类 app 引入 PPA 加速

不建议：

- 只为了“快”直接切 `LV_DISPLAY_RENDER_MODE_FULL`
- 没有 refresh_done 生命周期管理就启用大 buffer 双缓冲
- app 退出时随意 `disp_on_off(false)`
- 在 flush callback 中做复杂逻辑

## 12. 判断显示问题的日志线索

常见现象与方向：

| 现象 | 优先怀疑 |
| --- | --- |
| 返回 launcher 黑屏 | display owner 未释放、LVGL deinit 卡住、panel 被关屏 |
| FULL 模式闪烁 | buffer 被提前复用、flush_ready 过早、未等 refresh done |
| 局部花屏 | cache 未同步、DMA 读到旧数据、buffer 越界 |
| 首次启动黑一下 | 背光早于首帧内容打开 |
| 操作卡顿 | render/flush 同任务阻塞、任务优先级低、flush 过多 |
| 撕裂 | 非 VSYNC 边界提交、双缓冲生命周期不清晰 |

## 13. 核心结论

屏显优化的关键不是单点配置，而是完整链路：

```text
常驻 panel
+ 稳定 owner 生命周期
+ 明确 buffer 状态
+ refresh_done 驱动 buffer 释放
+ VSYNC 附近提交
+ cache coherency
+ 必要时 PPA/多核加速
```

ESP AI OS 后续优化应围绕这条链路逐步推进，避免一次性大改导致黑屏、闪屏和 owner 状态错乱。
