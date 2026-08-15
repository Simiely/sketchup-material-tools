# capabilities.md — 按材质合并插件功能清单

> 来源：material_merger.rb v2.0.0（273 行，逐行通读盘点）
> 日期：2026-08-15

## 入口（真实存在）

| 入口 | 位置(文件:行) | 说明 |
|---|---|---|
| 工具栏按钮「按材质合并」 | material_merger.rb:249-255 | UI::Command 触发 run |
| 菜单 扩展程序>按材质合并>按材质合并... | material_merger.rb:245-246 | add_submenu + add_item |
| 插件加载注册 | material_merger.rb:269-272 | file_loaded? 防重复 |

## 能力清单

| C-ID | 能力 | 实现位置 | 说明 |
|---|---|---|---|
| C-01 | 按材质合并（选中范围优先） | run:155-160 → merge_entities:91-129 | selection 中组/组件按材质分组合并 |
| C-02 | 按材质合并（未选中→全模型顶层） | run:162-165 | 回退逻辑：选中为空才全模型 |
| C-03 | 可选清理未使用组件定义 | run:211 + purge:134-146 | 需用户确认（MB_YESNOCANCEL） |
| C-04 | 大工程预警（≥3000 实体） | run:171-184 | MB_YESNO 二次确认 |
| C-05 | 进度显示（状态栏 % + 每 20 组刷视图） | run:199-210 | progress_cb 回调注入 |
| C-06 | 撤销（单步 undo） | run:195,222 | start_operation/commit_operation |
| C-07 | 出错回滚 + 失败实体不删除 | run:212-220 + merge_bucket:62-86 | abort_operation；failed 数组 |
| C-08 | 组→纯几何合并 | merge_bucket:67-73 | add_instance(定义)+explode |
| C-09 | 组件实例→保留实例（共享定义） | merge_bucket:74-79 | 复制 material/layer 覆盖 |
| C-10 | 批量删除源实体 | merge_entities:109-120 | erase_entities + 回退 erase! |

## 硬限制/关键规则（走查依据）

- 分组键 = 实体**顶层**材质（`e.material`），nil 归「默认材质」桶（material_key:47-49）
- 单实体桶跳过（merge_entities:98）
- 新组命名 `合并_材质名`、组材质继承（merge_entities:104-108）
- explode 返回 false → 撤销实例 + 标记失败不删源（merge_bucket:70-73）
- 复制失败实体从删除名单剔除（merge_entities:109-110）
- 无 active_path / 编辑态防护（**发现缺口，见报告 P-01**）
