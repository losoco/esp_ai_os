# ESP-Claw Launcher 开发计划

## 1. 目标

开发一个基于 Lua + LVGL 的 Android 风格 Launcher，作为 ESP-Claw 设备的常驻桌面入口。

Launcher 负责：

- 扫描 `/system/apps` 和 DATA 根下的 `apps/` 应用目录
- 展示应用图标、桌面、Dock、应用抽屉和设置入口
- 管理系统应用和用户应用的覆盖关系
- 启动独立 Lua 应用，并在应用退出后自动恢复 Launcher
- 提供最近任务、应用详情、基础设置和故障恢复能力

当前确认的首版范围：

- 阶段 1 + 阶段 2 骨架
- 现有应用迁移为目录包格式
- 应用退出后返回 Launcher

---

## 2. 关键约束

### 2.1 单 LVGL Runtime

当前 Lua LVGL 只有一个全局 Runtime，并记录创建它的 Lua State。Launcher 和子应用不能同时持有 LVGL 或 display。

因此应用启动流程必须是：

```text
Launcher 显示桌面
  -> 保存 Launcher 状态
  -> lvgl.deinit() 释放显示
  -> thread.start() 启动应用
  -> Launcher 进入无显示等待状态
  -> 应用退出
  -> Launcher 重新 lvgl.init()
  -> 恢复桌面
```

不能在 Launcher 持有 LVGL 的同时启动另一个会调用 `display.init()` 或 `lvgl.init()` 的应用。

### 2.2 应用根目录

系统应用：

```text
/system/apps
```

用户应用：

```text
storage.join_path(storage.get_root_dir(), "apps")
```

当前 metalio_claw_4 板卡 DATA 根通常是 `/sdcard`，但代码不能硬编码 `/sdcard`，需要通过 `storage.get_root_dir()` 获取。

### 2.3 覆盖策略

同一个 `app_id` 同时存在于 SYSTEM 和 DATA 时：

- DATA 应用优先
- 只有 DATA 应用 manifest 校验通过后才覆盖 SYSTEM 应用
- DATA 应用损坏时保留 SYSTEM 应用

### 2.4 `/system` 写保护

`/system` 在设计语义上是只读根。Launcher 不应提供修改、删除、更新 `/system/apps` 的功能。

用户应用安装、删除、更新只允许作用于 DATA 根的 `apps/`。

---

## 3. 应用包格式

### 3.1 目录结构

```text
/system/apps/<app-id>/
  manifest.json
  main.lua
  assets/

<DATA>/apps/<app-id>/
  manifest.json
  main.lua
  assets/
```

### 3.2 manifest.json

建议格式：

```json
{
  "schema_version": 1,
  "id": "tetris",
  "name": "Tetris",
  "version": "1.0.0",
  "description": "Classic Tetris with touch controls.",
  "entry": "main.lua",
  "icon": "assets/icon.bin",
  "category": ["game"],
  "requires": {
    "lua_modules": ["display", "board_manager", "delay"],
    "peripherals": ["display", "touch"]
  },
  "launch": {
    "timeout_ms": 0,
    "exclusive": "display",
    "replace": true
  }
}
```

### 3.3 校验规则

Launcher 扫描应用时必须校验：

- `schema_version == 1`
- `id` 必须存在，且与目录名一致
- `name` 必须存在
- `entry` 必须存在，且是相对路径
- `entry` 必须以 `.lua` 结尾
- `entry` 和 `icon` 禁止绝对路径
- `entry` 和 `icon` 禁止包含 `..`
- 入口文件必须存在
- 不支持的 manifest 直接跳过

---

## 4. Launcher 功能规划

## 4.1 阶段 1：可用桌面

目标：实现可运行、可启动应用、可恢复的 Launcher 主流程。

功能：

- LVGL 初始化和触摸注册
- SYSTEM/DATA 双根扫描
- manifest 解析和校验
- DATA 覆盖 SYSTEM 同 ID 应用
- 单页应用网格
- 顶部状态栏
- 底部 Dock
- 点击应用启动
- 应用退出后恢复 Launcher
- 启动失败弹窗
- 最近使用记录
- 基础设置持久化
- 字母图标 fallback

状态文件：

```text
<DATA>/launcher/settings.json
<DATA>/launcher/layout.json
<DATA>/launcher/history.json
```

## 4.2 阶段 2：完整 Launcher 骨架

目标：形成 Android 风格桌面结构，但复杂动画和拖拽可后续补充。

功能：

- 多页桌面
- 页码指示器
- Dock 固定应用
- 应用抽屉
- 分类过滤
- 搜索框
- 屏幕键盘
- 应用详情页
- 最近任务页
- 设置页
- 刷新应用列表
- 用户应用卸载入口
- 系统应用只读标识
- DATA 覆盖 SYSTEM 的来源提示
- 安全模式：配置损坏时恢复默认布局

## 4.3 阶段 3：高级体验

后续增强：

- 图标资源加载
- 壁纸
- 主题系统
- 图标编辑模式
- 图标移动、跨页和移入 Dock
- 启动和返回过渡动画
- SD 热插拔检测
- 全局 Home 键或 Home 手势
- 应用安装包导入
- 应用版本更新
- 失败应用自动禁用

---

## 5. UI 设计

### 5.1 顶部状态栏

显示：

- 时间
- 电池电量
- 存储状态
- 当前页面名称
- 后台任务状态

点击状态栏打开快捷面板。

### 5.2 桌面

布局建议：

- 720x720 屏幕
- 顶部状态栏：48px
- 主桌面区域：约 560px 高
- Dock：80px
- 每页 4x4 或 4x5 图标
- 图标使用圆角卡片 + 字母 fallback

### 5.3 应用抽屉

功能：

- 显示所有应用
- 分类筛选
- 搜索应用
- 最近使用和收藏入口
- 长按打开应用详情

### 5.4 应用详情页

显示：

- 名称
- 版本
- 描述
- 来源：system/data
- 入口路径
- 分类
- 所需模块和外设
- 启动次数
- 最近启动状态

操作：

- 启动
- 固定到桌面
- 从桌面移除
- 卸载用户应用
- 查看覆盖关系

### 5.5 最近任务页

显示：

- 最近启动过的应用
- 当前运行状态
- 最后启动时间
- 最近错误摘要

操作：

- 重新启动
- 停止运行中的任务
- 清空历史

### 5.6 设置页

设置项：

- 主题：深色/浅色
- 图标大小
- 桌面网格行列
- Dock 数量
- 默认首页
- 应用排序方式
- 是否显示系统应用
- 是否显示来源标识
- 重置桌面布局
- 刷新应用列表

---

## 6. 代码结构规划

建议 Launcher 自身也作为标准应用包：

```text
/system/apps/launcher/
  manifest.json
  main.lua
  lib/
    app_registry.lua
    app_runner.lua
    state_store.lua
    theme.lua
    widgets.lua
    ui_statusbar.lua
    ui_desktop.lua
    ui_drawer.lua
    ui_recents.lua
    ui_settings.lua
    ui_app_detail.lua
  assets/
```

### 6.1 main.lua

职责：

- 初始化 LVGL
- 注册触摸输入
- 加载设置和布局
- 调用 app_registry 扫描应用
- 创建主 UI
- 管理主状态机
- 处理 Launcher 暂停、恢复和退出

### 6.2 app_registry.lua

职责：

- 扫描 `/system/apps`
- 扫描 DATA 根 `apps/`
- 读取 `manifest.json`
- 校验 manifest
- 合并 SYSTEM/DATA 应用
- 输出应用列表和错误列表

### 6.3 app_runner.lua

职责：

- 保存 Launcher 当前页面状态
- 释放 LVGL
- 使用 `thread.start()` 启动应用
- 轮询应用状态
- 应用退出后重新初始化 Launcher
- 捕获启动失败和运行错误

建议启动参数：

```lua
thread.start(entry_path, {}, {
    name = "app:" .. app.id,
    exclusive = "display",
    replace = true,
    timeout_ms = app.launch.timeout_ms or 0,
})
```

### 6.4 state_store.lua

职责：

- 读写 settings/layout/history
- 配置损坏时恢复默认值
- 限制历史记录数量
- 保存最近使用应用

### 6.5 theme.lua

职责：

- 颜色表
- 字体大小
- 尺寸常量
- 深色/浅色主题切换

### 6.6 widgets.lua

职责：

- 应用图标组件
- 状态栏组件
- Dock 图标
- 卡片
- 设置项
- 空状态提示
- 错误对话框

### 6.7 ui_* 模块

各页面独立模块：

- `ui_statusbar.lua`
- `ui_desktop.lua`
- `ui_drawer.lua`
- `ui_recents.lua`
- `ui_settings.lua`
- `ui_app_detail.lua`

每个模块提供：

```lua
create(parent, ctx)
destroy()
refresh(data)
```

---

## 7. 应用迁移计划

现有平铺 Lua 应用迁移为目录包。

示例：

```text
apps/tetris.lua
```

迁移为：

```text
application/edge_agent/fatfs_image/apps/tetris/
  manifest.json
  main.lua
```

或开发期使用：

```text
<DATA>/apps/tetris/
  manifest.json
  main.lua
```

迁移原则：

- 原脚本内容尽量不改，仅改名为 `main.lua`
- manifest 补充名称、分类、入口和硬件需求
- 所有应用保持长按退出
- 应用退出时必须释放 display/LVGL 资源
- 迁移后 Launcher 只识别目录包，不再直接识别平铺脚本

首批建议迁移：

- dashboard
- bubble_level
- tilt_maze
- snake
- particles
- paint
- breakout
- dice
- g2048
- simon
- tetris
- minesweeper
- flappy
- slide_puzzle
- chess
- sensor_hub

---

## 8. 启动与恢复流程

### 8.1 启动应用

```text
用户点击应用图标
  -> app_registry 返回 app entry
  -> app_runner 保存 Launcher 状态
  -> UI 显示启动遮罩
  -> lvgl.deinit()
  -> thread.start(app entry)
  -> Launcher 进入无显示等待循环
```

### 8.2 应用运行中

Launcher 不持有 LVGL/display，只做：

- 周期性 `thread.get("app:<id>")`
- 检查应用是否结束
- 记录运行结果
- 必要时处理停止请求

### 8.3 应用结束

```text
thread.get() 返回 done/stopped/error
  -> 记录历史
  -> 重新 lvgl.init()
  -> 重建 UI
  -> 回到启动前页面
  -> 如有错误，弹出错误对话框
```

---

## 9. 错误处理

### 9.1 manifest 错误

- 单个应用 manifest 失败不影响 Launcher
- 错误应用进入 invalid 列表
- 设置中可查看 invalid 应用和原因
- DATA invalid 不覆盖 SYSTEM valid

### 9.2 启动失败

- 显示错误弹窗
- 记录到 history
- 返回桌面

### 9.3 应用运行失败

- 记录错误摘要
- 最近任务页显示失败状态
- 连续失败超过阈值可提示禁用

### 9.4 Launcher 配置损坏

- settings/layout/history 单独读取
- 任一文件损坏只重置该项
- 不影响应用扫描和启动

---

## 10. 第一版交付标准

第一版完成后应满足：

- Launcher 可从 Lua 脚本启动
- 可扫描 `/system/apps` 和 DATA `apps/`
- 可显示至少 10 个迁移后的应用
- 可点击启动任意应用
- 应用退出后自动回到 Launcher
- 可进入应用抽屉
- 可进入应用详情页
- 可进入设置页
- 配置和历史可持久化
- manifest 损坏不会导致 Launcher 崩溃
- 设备运行 5 分钟无崩溃
- 至少测试 3 个 display 应用启动和返回

---

## 11. 后续可能需要的底层增强

首版可纯 Lua 实现，但建议后续补充：

1. LVGL 通用手势事件：滑动方向、坐标、拖动。
2. LVGL 通用动画 API：位置、透明度、缩放、转场。
3. 系统级 Home 键或 Home 手势。
4. 应用管理 C API：前台应用、停止、返回 Launcher。
5. Lua storage 对 `/system` 的写保护。
6. SD/USB MSC 锁状态 Lua API。
7. Wi-Fi/IP 状态 Lua API。
8. 应用安装包导入和签名校验。

---

## 12. 实施顺序建议

1. 创建 Launcher 目录包和基础 `main.lua`
2. 实现 LVGL 初始化、触摸注册和基础桌面 UI
3. 实现 `app_registry.lua`
4. 定义 manifest 规范并迁移 2-3 个应用验证
5. 实现点击启动和退出恢复
6. 实现应用抽屉骨架
7. 实现设置和状态持久化
8. 批量迁移现有应用
9. 实现最近任务和应用详情
10. 设备长时间运行测试

---

## 13. 当前结论

现有 Lua LVGL、storage、json、thread 能力已经足够实现首版 Launcher。

最关键的工程点不是 UI，而是生命周期：Launcher 必须在启动子应用前释放 LVGL/display，并在子应用退出后重建自身 UI。

建议按“阶段 1 + 阶段 2 骨架”的范围开发，先保证稳定可用，再逐步补动画、拖拽和系统级 Home 能力。
