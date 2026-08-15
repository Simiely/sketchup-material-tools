# DEVELOPMENT.md · 开发说明

> 给开发者（自己）看：项目概览 → 架构说明 → 关键问题与方案。
> 坑库（编号 P-xx）见 [docs/09-pitfalls.md](docs/09-pitfalls.md)；场景走查（15 条链路）见 [docs/walkthrough/report.md](docs/walkthrough/report.md)。

## 一、项目概览

两个配套的 SketchUp Ruby 插件，解决"SKP 文件太大 + 导出到 Blender"两个场景：

| 插件 | 文件 | 职责 |
|---|---|---|
| 按材质合并 v2.7.1 | `material_merger.rb` | 同材质实体合并为一个组（组件实例保留共享定义）+ 清理未使用组件定义 |
| 导出到 Blender v1.0.1 | `su_blender_export.rb` + `su_to_blender_import.py` | 贴图文件名转英文 + 导出保留实例的 DAE + 自动启动 Blender 导入 |

## 二、架构说明

### material_merger.rb（合并插件）

```
run (入口: 面板/工具栏/菜单)
 ├─ 三道闸: 防重入(@running) / 编辑态(active_path+close_active) / 确认(预警+清理选择)
 ├─ 收集: 选中范围优先, 否则全模型顶层组/组件
 ├─ 大任务(≥100 实体): AsyncMergeRunner 实体级时间片分块
 │    └─ UI.start_timer(0.02s) 链式调度, 每块 0.15s 内逐实体处理
 │         └─ copy_entity_to_group: 组→add_instance+explode 炸开复制; 实例→保留
 │              └─ 桶内全部处理完 → erase_entities 批量删源(失败实体不删)
 ├─ 小任务: 同步 merge_entities
 └─ 收尾: purge_unused_definitions(可选) → commit/abort → show_result
```

- **进度显示接口统一**：`ControlPanel`（常驻面板）与 `ProgressDisplay`（弹窗/状态栏）实现同一接口（`update` / `cancelled?` / `show_result` / `close`），`run` 按面板是否可见选择载体
- **取消/回滚**：取消标志 → `OperationCancelled` → `abort_operation` 整体回滚，不留下半成品
- **实体级分块原理**：见 CHANGELOG v2.5.0；单实体复制是毫秒级原子操作，时间片让出事件泵 → 任意规模界面不冻结

### su_blender_export.rb（导出插件）

```
run_export (一键)
 ├─ rename_textures_to_ascii: 贴图转英文
 │    └─ tex.filename → texture.write(tex_0001.png) → material.texture= → 恢复 size/color
 │    （幂等: tex_xxxx 前缀跳过; 存模型同目录 <模型名>_textures/）
 ├─ model.export(DAE, preserve_instancing:true, triangulated_faces:false)
 └─ spawn("blender --python su_to_blender_import.py -- dae") 非阻塞启动
```

### 关键设计决策

- **不预三角化导出**：`triangulated_faces: false`（Blender 导入自行三角化）——大模型预三角化是导出卡顿大头（见 CHANGELOG v1.0.1）
- **贴图由内核写出**：`texture.write` 不依赖原文件路径（SKP 内嵌纹理的原路径可能不存在）
- **Blender 自动查找**：扫描 `C:\Program Files\Blender Foundation\Blender*/blender.exe` + `BLENDER_EXE` 环境变量，取版本最高

## 三、关键问题与方案（一坑一篇）

> 完整坑库见 [docs/09-pitfalls.md](docs/09-pitfalls.md)，此处记录 DEVELOPMENT 视角的关键问题。

### 问题：v1 使用了不存在的 API `transform_by_entities`

**TL;DR**：官方 API 无复制实体方法，社区标准是 `add_instance(定义, 变换) + explode`。

- 问题：v1 合并核心逐实体调用 `transform_by_entities`，一运行即 NoMethodError
- 根因：凭记忆写 API，未核对官方文档（文档只有 `transform_entities` 移动变换；复制实体无官方方法，官方 issue-tracker #41 至今未加）
- 解决：改为"实例化定义 + 炸开"——`new_group.entities.add_instance(e.definition, e.transformation)` 后 `inst.explode`，内核整块复制（保留材质/图层/UV），性能提升数个量级
- 预防：任何 SketchUp API 使用前查 ruby.sketchup.com / 官方论坛

### 问题：大模型下"点开始合并就卡死"

**TL;DR**：分块粒度必须是"实体级"，桶级分块挡不住单桶海量实体。

- 问题：v2.3 按材质桶分块，但组件为主的模型所有实例归入「默认材质」一个桶（实例 `e.material` 基本为 nil），几万~几十万实体在同一个时间片内循环 → 主线程长时间占满
- 根因：时间片检查只在桶之间，桶内 `merge_bucket` 循环不分块
- 解决：v2.5 `AsyncMergeRunner` 重写为实体级分块——`@bucket_list` + `@item_index` 游标，时间片内逐实体处理，桶内实体处理完才批量删源
- 预防：凡 `UI.start_timer` 分块的循环，时间片检查必须在最细粒度（单实体/单原子操作）

### 问题：清理/合并后 SketchUp 卡死

**TL;DR**：大模型下 `active_view.refresh` 是全量重绘，能不用就不用。

- 问题：v2.6.0 清理后调用 `active_view.refresh`，大模型（百万面级）全量重绘可卡几十秒甚至更久
- 根因：把"刷新视图"当成无成本操作；实际 refresh = 强制重绘整个场景
- 解决：v2.6.2 移除收尾 refresh（视图在用户交互时自然重绘）；分块间隙的每块 refresh 一并移除，仅完成时一次
- 预防：大模型环境默认不主动 refresh；进度靠面板/状态栏，不靠视图

### 问题：导出大模型卡在 18% 很久

**TL;DR**：18% 是 SketchUp 自身导出进度；预三角化是早期大头开销，关闭即可。

- 问题：导出 497MB 模型（内部几何数据 1.6GB）时进度卡 18% 数分钟
- 根因：① 导出是 SketchUp 单线程同步操作（期间界面无响应）② `triangulated_faces: true` 让导出器在早期把所有面三角化（几何大头开销）
- 解决：v1.0.1 `triangulated_faces: false` + 导出前按面数（`model.statistics[:faces]`）预告等待时间
- 预防：大模型先瘦身（合并/清理隐藏几何/压缩贴图）再导出；必要时分块（只导出选中实体）

### 问题：贴图文件名含中文/空格，导入 Blender 丢失

**TL;DR**：用 `texture.write` 由内核导出为英文文件名并重新指向，恢复尺寸/颜色。

- 问题：模型贴图多为中文名（且带 `[导入的]` 嵌套材质），DAE 导出 + Blender 导入时贴图丢失
- 根因：非 ASCII/空格路径跨软件传递不稳定；SKP 内嵌纹理的原文件路径可能不存在（无法直接复制）
- 解决：`tex.filename` 取路径 → `texture.write(新路径)` 内核写出 → `material.texture = 新路径` → 恢复 `texture.size=[w,h]` 与 `material.color`（重设纹理丢这两项）；`tex_%04d` 命名保证不重复；已转（`tex_` 前缀）跳过实现幂等
- 预防：重设 `material.texture=` 后必须恢复尺寸与颜色，否则 UV/外观错乱

## 四、SKP 文件分析速查（本仓库已用）

- SKP 2021+ 是 ZIP 压缩存储：头部 `SketchUp Model {24.xxxx}` + VFF + `PK` 签名，Python zipfile 可直接解析
- 内部：`model.dat`（几何数据，通常占 90%+）、`materials/`（内嵌贴图）、`xml`（元数据）
- 分析方法：zipfile 列出条目按扩展名汇总，**大文件勿全量解压**（`model.dat` 解压 1.6GB）
