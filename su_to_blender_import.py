# -*- coding: utf-8 -*-
# su_to_blender_import.py
# 由 SketchUp 插件 material_merger.rb 调用:
#   blender.exe --python 本脚本 -- "xxx.dae"
# 作用: 清空默认场景 -> 导入 Collada(保留实例/层级) -> 设置公制单位 -> 聚焦视角
# 不带 --background 启动, 脚本执行完后 Blender 保持打开显示模型

import sys
import os

import bpy


def main():
    args = sys.argv
    filepath = None
    if '--' in args:
        rest = args[args.index('--') + 1:]
        if rest:
            filepath = rest[0]

    if not filepath:
        print('[su-to-blender] 未收到 DAE 文件路径参数')
        return

    if not os.path.isfile(filepath):
        print('[su-to-blender] DAE 文件不存在:', filepath)
        return

    # 清空默认场景(不加载默认启动文件)
    bpy.ops.wm.read_factory_settings(use_empty=True)

    # 导入 Collada(SketchUp 导出时已勾选 preserve_instancing, 层级/实例随之保留)
    bpy.ops.wm.collada_import(filepath=filepath)

    # 单位设置为公制
    bpy.context.scene.unit_settings.system = 'METRIC'

    # 尝试让视角聚焦到模型(失败不影响导入结果)
    try:
        bpy.ops.object.select_all(action='SELECT')
        bpy.ops.view3d.view_selected(use_all_regions=False)
    except Exception as exc:  # noqa: BLE001
        print('[su-to-blender] 视角调整跳过:', exc)

    print('[su-to-blender] 导入完成:', filepath)


if __name__ == '__main__':
    main()
