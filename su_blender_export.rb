#==============================================================================
# su_blender_export.rb  v1.0.0
# 独立插件: 一键导出 SketchUp 模型到 Blender
#
# 功能:
#   1. 贴图文件名转英文: 把模型所有贴图导出为英文文件名(tex_0001.png 形式,
#      字母+序号, 不重复), 存入模型同目录 <模型名>_textures/ 文件夹,
#      并让材质重新指向新文件(保留尺寸/颜色)——解决中文/空格贴图文件名
#      在 Blender 导入时丢失的问题
#   2. 一键导出到 Blender: 转换贴图 -> 导出 Collada(.dae, 保留实例) ->
#      自动查找本机 Blender -> 非阻塞启动 Blender 自动导入
#
# 依赖: su_to_blender_import.py 必须与本文件放在同一目录
#   (rbz 安装包已内置; 手动拷贝安装时两个文件一起复制)
#
# 依据:
#   - ruby.sketchup.com Exporter Options: DAE 导出 preserve_instancing
#   - Sketchup::Texture#write / Material#texture= / Texture#size=
#     (官方文档 + 社区 TIG 的 RenameTextures 方案)
#
# 安装: %APPDATA%\SketchUp\SketchUp 20xx\SketchUp\Plugins\
# 兼容: SketchUp 2017+ (Texture#write 需 2016+, HtmlDialog 需 2019+, 旧版降级)
#==============================================================================

require 'sketchup.rb'
require 'fileutils'

module WB
  module BlenderExport

    PLUGIN_NAME    = '导出到 Blender'
    PLUGIN_VERSION = '1.0.1'

    # 调试输出开关
    DEBUG_MODE = false

    #----------------------------------------------------------------------
    # JS 转义(execute_script 参数安全)
    #----------------------------------------------------------------------
    def self.js_escape(text)
      text.to_s.gsub(/[\\'\n]/) do |m|
        case m
        when '\\' then '\\\\'
        when "'"  then "\\'"
        else ' '
        end
      end
    end

    #----------------------------------------------------------------------
    # 控制面板(常驻窗口): 一键导出按钮 + 贴图转换按钮 + 状态区
    #----------------------------------------------------------------------
    class Panel
      PANEL_HTML = <<~HTML
        <style>
          body { font-family: 'Segoe UI', sans-serif; padding: 14px; background: #2b2b2b; color: #e8e8e8; margin: 0; }
          h3 { margin: 0 0 6px 0; font-size: 14px; font-weight: 500; }
          .hint { font-size: 11px; color: #999; margin-bottom: 10px; }
          .info { font-size: 12px; color: #ccc; min-height: 48px; margin-bottom: 10px; word-break: break-all; }
          .row { margin-top: 8px; display: flex; gap: 8px; }
          .btn { flex: 1; padding: 6px 0; border: none; border-radius: 4px; cursor: pointer; font-size: 13px; }
          .primary { background: #378add; color: #fff; }
          .primary:hover { background: #185FA5; }
          .ghost { background: #555; color: #ddd; }
          .ghost:hover { background: #6b6b6b; }
          .tip { margin-top: 10px; font-size: 11px; color: #777; }
        </style>
        <h3>导出到 Blender</h3>
        <div class="hint">一键: 贴图转英文名 &rarr; 导出 DAE(保留实例) &rarr; 自动导入 Blender</div>
        <div class="info" id="info">就绪</div>
        <div class="row">
          <button class="btn primary" onclick="sketchup.export()">一键导出到 Blender</button>
        </div>
        <div class="row">
          <button class="btn ghost" onclick="sketchup.rename()">仅转换贴图为英文</button>
        </div>
        <div class="tip">关闭后重开: 扩展程序 &gt; 导出到 Blender &gt; 打开面板</div>
        <script>
          function setStatus(t) { document.getElementById('info').textContent = t; }
        </script>
      HTML

      def initialize
        @dialog = UI::HtmlDialog.new(
          dialog_title: '导出到 Blender',
          preferences_key: 'wb_blender_export.panel',
          width: 360, height: 252, min_width: 320, min_height: 210,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_html(PANEL_HTML)
        @dialog.add_action_callback('export') { |_a, _p| WB::BlenderExport.run_export }
        @dialog.add_action_callback('rename') { |_a, _p| WB::BlenderExport.rename_textures_only }
        @dialog.show
      end

      def visible?
        @dialog.visible?
      rescue StandardError
        false
      end

      def show
        @dialog.show
      rescue StandardError
        nil
      end

      def set_status(text)
        @dialog.execute_script("setStatus('#{WB::BlenderExport.js_escape(text)}')")
      rescue StandardError
        nil
      end
    end

    #----------------------------------------------------------------------
    # 打开控制面板
    #----------------------------------------------------------------------
    def self.open_panel
      if @panel && @panel.visible?
        @panel.show
      else
        @panel = Panel.new
      end
    rescue StandardError => e
      UI.messagebox("打开面板失败: #{e.message}", MB_OK)
    end

    #----------------------------------------------------------------------
    # 面板状态输出(面板打开则推面板, 否则弹窗)
    #----------------------------------------------------------------------
    def self.report(message)
      if @panel && @panel.visible?
        @panel.set_status(message)
      else
        UI.messagebox(message, MB_OK)
      end
    end

    #----------------------------------------------------------------------
    # 查找 Blender 可执行文件(常见安装路径 + BLENDER_EXE 环境变量, 取最高版本)
    #----------------------------------------------------------------------
    def self.find_blender
      candidates = []
      base = 'C:/Program Files/Blender Foundation'
      begin
        if File.directory?(base)
          Dir.glob(File.join(base, 'Blender*', 'blender.exe')).each { |p| candidates << p }
        end
      rescue StandardError
      end
      if ENV['BLENDER_EXE'] && File.exist?(ENV['BLENDER_EXE'])
        candidates << ENV['BLENDER_EXE']
      end
      candidates.uniq!
      return nil if candidates.empty?

      candidates.max_by do |p|
        nums = File.basename(File.dirname(p)).scan(/\d+/).map(&:to_i)
        nums.empty? ? [0, 0, 0] : nums
      end
    end

    #----------------------------------------------------------------------
    # 贴图文件名转英文:
    #   - 遍历所有带纹理的材质, 用 texture.write 由内核导出贴图数据
    #     为 tex_0001.png 形式(字母+序号, 不重复), 存入模型同目录
    #     <模型名>_textures/ 文件夹
    #   - 材质重新指向新文件, 恢复纹理尺寸与材质颜色
    #   - 已转换(tex_xxxx 前缀)的贴图跳过, 幂等
    # 返回: [转换数量, 目标文件夹, 错误信息(nil 为成功)]
    #----------------------------------------------------------------------
    def self.rename_textures_to_ascii(model)
      model_path = model.path
      if model_path.nil? || model_path.empty?
        return [0, nil, '模型尚未保存, 请先保存模型再转换贴图。']
      end

      dir = File.join(File.dirname(model_path), File.basename(model_path, '.*') + '_textures')
      begin
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
      rescue StandardError => e
        return [0, nil, "创建贴图目录失败: #{e.message}"]
      end

      textured = []
      model.materials.each { |m| textured << m if m.texture }

      count = 0
      index = 0
      model.start_operation('转换贴图为英文文件名', true)
      textured.each do |m|
        begin
          tex = m.texture
          old_name = File.basename(tex.filename.to_s)
          # 已是 tex_xxxx 形式的跳过(幂等)
          next if old_name =~ /\Atex_\d{4,}\./i

          w = tex.width
          h = tex.height
          col = m.color

          ext = File.extname(old_name)
          ext = '.png' if ext.nil? || ext.empty? || ext.length > 6

          # 生成不重复的英文文件名(字母+序号)
          new_name = nil
          loop do
            index += 1
            cand = format('tex_%04d%s', index, ext.downcase)
            unless File.exist?(File.join(dir, cand))
              new_name = cand
              break
            end
          end
          new_path = File.join(dir, new_name)

          # 由 SketchUp 内核写出纹理数据(不依赖原文件路径, 原文件可能不存在)
          next unless tex.write(new_path)

          # 重新指向新文件, 恢复尺寸与颜色(重设纹理会丢这两项)
          m.texture = new_path
          begin
            m.texture.size = [w, h]
          rescue StandardError
          end
          begin
            m.color = col
          rescue StandardError
          end
          count += 1
        rescue StandardError => e
          puts "贴图转换失败 #{m.display_name}: #{e.message}" if DEBUG_MODE
        end
      end
      model.commit_operation
      [count, dir, nil]
    end

    #----------------------------------------------------------------------
    # 仅转换贴图为英文(面板按钮)
    #----------------------------------------------------------------------
    def self.rename_textures_only
      model = Sketchup.active_model
      unless model
        UI.messagebox('没有打开的模型!')
        return
      end
      count, dir, err = rename_textures_to_ascii(model)
      if err
        report(err)
      else
        report("贴图转换完成: #{count} 个贴图已转为英文文件名。\n存储位置: #{dir}\n\n材质已重新指向新文件, 导出时不再丢失贴图。")
      end
    end

    #----------------------------------------------------------------------
    # 一键导出到 Blender(面板主按钮):
    #   转换贴图 -> 导出 DAE(保留实例) -> 启动 Blender 自动导入
    #----------------------------------------------------------------------
    def self.run_export
      model = Sketchup.active_model
      unless model
        UI.messagebox('没有打开的模型!')
        return
      end

      blender = find_blender
      unless blender
        report("未找到 Blender。\n请确认已安装 Blender, 或设置环境变量 BLENDER_EXE\n指向 blender.exe 的完整路径后重启 SketchUp。")
        return
      end

      # 1) 贴图转英文(幂等)
      count, dir, err = rename_textures_to_ascii(model)
      tex_msg = if err
                  "贴图: #{err}"
                elsif count.zero?
                  '贴图: 无需转换(全部已是英文名)'
                else
                  "贴图: #{count} 个已转英文名 -> #{dir}"
                end

      # 2) 规模预告: 导出是 SketchUp 单线程同步操作, 大模型期间界面无响应
      begin
        faces = model.statistics[:faces].to_i
        if faces >= 500_000
          proceed = UI.messagebox(
            "模型较大(约 #{faces} 面)。\n" \
            "导出需要数分钟, 期间 SketchUp 会显示自己的进度条,\n" \
            '界面暂时无响应属正常, 请不要关闭或强制结束 SketchUp。\n\n' \
            '是否继续?',
            MB_YESNO
          )
          return unless proceed == 6 # YES
        end
      rescue StandardError
        # 统计失败则跳过预告
      end

      # 3) 导出 DAE(保留实例; 不预三角化——大模型三角化是导出卡顿大头,
      #    Blender 导入 DAE 自己会处理三角面)
      dae_path = File.join(Dir.tmpdir, 'wb_blender_export.dae')
      begin
        status = model.export(dae_path, {
          :triangulated_faces    => false,
          :doublesided_faces     => true,
          :edges                 => false,
          :author_attribution    => false,
          :texture_maps          => true,
          :selectionset_only     => false,
          :preserve_instancing   => true,
          :show_summary          => false
        })
      rescue StandardError => e
        report("导出 DAE 失败: #{e.message}")
        return
      end
      unless status
        report('导出 DAE 失败(未返回成功)。')
        return
      end

      # 4) 启动 Blender 自动导入(非阻塞)
      script = File.join(File.dirname(__FILE__), 'su_to_blender_import.py')
      cmd = "\"#{blender}\" --python \"#{script}\" -- \"#{dae_path}\""
      begin
        spawn(cmd)
      rescue StandardError => e
        report("启动 Blender 失败: #{e.message}\n\nDAE 已导出到:\n#{dae_path}\n可手动导入 Blender。")
        return
      end

      report("已导出并发送到 Blender!\n\n#{tex_msg}\n\n" \
             "DAE: #{dae_path}\nBlender 正在启动并导入(组件实例已保留), 请稍候。\n\n" \
             '提示: 导出大模型可能需要一点时间。')
    end

    #----------------------------------------------------------------------
    # 注册菜单与工具栏
    #----------------------------------------------------------------------
    def self.register
      unless @loaded
        @loaded = true

        menu = UI.menu('Extensions').add_submenu(PLUGIN_NAME)
        menu.add_item("打开面板...") { open_panel }
        menu.add_item("一键导出到 Blender...") { run_export }
        menu.add_item("仅转换贴图为英文...") { rename_textures_only }

        @toolbar = UI::Toolbar.new(PLUGIN_NAME)
        cmd_export = UI::Command.new("导出到 Blender") { run_export }
        cmd_export.tooltip = '一键导出到 Blender(转换贴图 + 导出 DAE + 自动导入)'
        cmd_export.status_bar_text = '一键导出 SketchUp 模型到 Blender'
        cmd_export.menu_text = '一键导出到 Blender...'
        @toolbar = @toolbar.add_item(cmd_export)

        cmd_panel = UI::Command.new("打开面板") { open_panel }
        cmd_panel.tooltip = '打开导出到 Blender 控制面板'
        cmd_panel.status_bar_text = '打开控制面板: 一键导出 + 贴图转换'
        cmd_panel.menu_text = '打开面板...'
        @toolbar = @toolbar.add_item(cmd_panel)
        @toolbar.show
      end
    end

  end
end

unless file_loaded?(__FILE__)
  WB::BlenderExport.register
end
file_loaded(__FILE__)
