# AGENTS.md · 项目规则

> 📌 **文档基线**：2026-08-15（commit `c0042bfa`）完成四件套重写（README/AGENTS/DEVELOPMENT/CHANGELOG）
> **更新文档/代码后，请更新此行**（日期 + 新 commit hash），并在 CHANGELOG 追加版本

## 技术栈

- SketchUp 2026（模型格式 24.0484）Ruby API，兼容 SU 2017+（`Texture#write` 需 2016+，`UI::HtmlDialog` 需 2019+，旧版自动降级为状态栏/菜单模式）
- Blender 5.2 LTS Python（`su_to_blender_import.py` 配套脚本）
- SKP 2021+ 为 ZIP 压缩存储（可 zipfile 解析内部结构：`model.dat` 几何 / materials/ 贴图 / xml 元数据）

## 关键坑（3~5 条，越具体越好）

- **`transform_by_entities` 不存在**：SketchUp API 只有 `transform_entities`（移动），复制实体用社区标准"`add_instance(定义, 变换)` + `explode`"（内核整块复制）
- **大模型下 `active_view.refresh` = 全量重绘，会卡死**：能不用就不用（视图在用户交互时自然重绘）；分块间隙绝不刷新，仅收尾一次
- **大任务必须"实体级"分块**：`UI.start_timer` 时间片只检查桶级会让单桶（几万~几十万同材质实体）卡死；时间片内逐实体处理
- **编辑态（`active_path` 非空）批量操作 = 位置错乱/崩溃**：入口必须检测，可选 `model.close_active` 自动退出
- **`material.texture = 新路径` 会丢纹理尺寸与颜色**：重设后必须恢复 `texture.size = [w,h]` 与 `material.color`
- **迭代集合时不要删除元素**：purge 类操作先收集数组再删

## 约定

- UI 标签中文；注释中文；唯一命名空间 `WB::<Plugin>`
- rbz 打包：Ruby 用 zipfile 写入 rb（+ 配套 py 同目录）；两个文件必须同目录安装
- 本机安装目录（Windows）：`%APPDATA%\SketchUp\SketchUp 20xx\SketchUp\Plugins\`（macOS: `~/Library/Application Support/SketchUp 20xx/SketchUp/Plugins/`）
- 发布：README + AGENTS + DEVELOPMENT + CHANGELOG 四件套 → knowledge-base `仓库盘点表.md` 回填

## 常用命令

- 打包 rbz：`python -c "import zipfile; zipfile.ZipFile('x.rbz','w',zipfile.ZIP_DEFLATED).write('f.rb','f.rb')"`（多文件逐个 write）
- 分析 SKP 内部：Python zipfile 列出条目（`model.dat` 是几何数据，大文件勿全量解压）
- 推 GitHub：Contents API 逐文件 PUT（沙箱 git push 不通），见用户库 github-contents-api-push 技能

## 详细规则（按需 @引用）

- @docs/09-pitfalls.md（坑库，走查沉淀）
- @docs/walkthrough/（场景走查：capabilities / scenarios / report）
