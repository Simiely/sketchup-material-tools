# 坑库 (Pitfalls)

> 来源：scenario-walkthrough 场景走查 · 2026-08-15
> 状态流转：open → fixed → verified

## P-01 组/组件编辑态运行导致位置错乱/潜在崩溃

- **现象**：在组内编辑态（active_path 非空）运行插件：选中实体 `e.transformation` 是相对父组的局部坐标，add_instance 直接用作世界变换 → 合并位置错乱；erase_entities 删除编辑路径内实例在 SU<2023 可能崩溃、2023.0.x 抛 ArgumentError。
- **原因**：收集顶层实体时未检查 active_path；SketchUp 官方文档明确 erase_entities 对编辑路径内实体的限制。
- **解决**：run 收集前检测 `model.active_path` 非空 → 提示「请先退出组/组件编辑状态」并中止（material_merger.rb:164-171）。
- **预防**：涉及批量变换/删除的插件，入口必须做 active_path 守卫；变换一律只用世界坐标。
- **相关**：S-15；官方文档 ruby.sketchup.com/Sketchup/Entities.html#erase_entities

## P-02 组件实例无覆盖材质时全归「默认材质」桶

- **现象**：组件实例 `instance.material` 通常为 nil（材质在定义/面内），按实体顶层材质分组会把组件为主的模型全部并入一个「合并_默认材质」组，与"按材质"直觉不符。
- **原因**：material_key 只取 `e.material`，未回退 definition 材质。
- **解决**：README 明确分组规则；可选增强——实例回退 `e.definition` 材质分组（待用户确认是否需要）。
- **预防**：按材质分组的插件需明确"顶层材质 vs 面材质 vs 定义材质"的取值语义。
- **相关**：S-14；状态 open（文档已澄清，代码增强待定）

## P-03 puts 调试输出残留

- **现象**：merge_bucket rescue 里 puts 输出到 Ruby Console，违反官方发布禁令。
- **解决**：改为 `DEBUG_MODE` 常量开关（默认 false）（material_merger.rb:35,84）。
- **预防**：发布前 grep `puts|print|p(` 清理或开关化。
- **相关**：S-09/S-10；状态 fixed
