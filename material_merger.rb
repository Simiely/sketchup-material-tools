#==============================================================================
# material_merger.rb  v2.7.1
# 按材质合并实体插件 - 减小 SKP 文件体积
#
# v2.7.1 功能拆分(2026-08): 导出到 Blender 功能已迁移至独立插件
#   su_blender_export.rb(含贴图文件名转英文功能), 本插件专注合并+清理
#
# v2.6 独立清理按钮(2026-08):
#   - 控制面板新增「清理未使用数据」按钮(独立于合并流程):
#     一键清理所有无实例引用的组件定义, 带确认/回滚/结果推面板
#   - 菜单新增「清理未使用数据...」入口
#
# v2.5 实体级分块(2026-08, 修复"点开始合并就卡死"):
#   - 关键修复: 分块粒度从"材质桶"下沉到"单个实体"——之前一个桶内
#     所有实体在一个块内循环处理(同材质实体量大时单块长时间占满主线程),
#     现在每块按时间片逐实体处理, 任意规模都不再卡死界面
#   - 新增 copy_entity_to_group 单实体复制(异步/同步路径共用)
#
# v2.4 控制面板(2026-08):
#   - 新增常驻控制面板窗口: 一个「开始合并」按钮 + 取消按钮 +
#     进度条 + 状态显示区(任务进行中实时百分比/材质名, 完成后显示结果)
#   - 面板打开时即作为进度载体(替代临时进度弹窗), 结果直接显示在面板
#   - 菜单/工具栏新增「控制面板」入口
#
# v2.3 异步分块(2026-08, 解决大批量任务导致界面冻结/"未响应"):
#   - 大任务(>=100 实体)改为异步分块执行: 每块处理约 0.15s 的材质桶,
#     然后让出事件泵(UI.start_timer 链式调度下一块), 界面保持响应
#   - 进度实时更新; 取消随时生效(块间隙响应); 取消/出错整体回滚
#   - 防重入: 合并进行中重复触发会提示
#
# v2.2 进度弹窗(2026-08):
#   - 大任务(>=100 实体)弹出 HtmlDialog 进度条(无面板时), 可取消
#   - 小任务保持状态栏进度(零开销)
#
# v2.1 修复(场景走查 P-01/P-03):
#   - 编辑态防护: active_path 非空时提示先退出编辑
#   - puts 调试输出改为 DEBUG_MODE 开关
#
# v2.0 性能重构(2026-08):
#   - 修复 v1 致命问题: 弃用不存在的 transform_by_entities API
#   - 改用社区标准"实例化定义+炸开"批量复制法(SketchUp 内核整块操作)
#     依据: 官方论坛 "Copy entities" 帖 / api-issue-tracker #41
#   - 源组件实例保留为实例(共享定义, 文件最紧凑); 源组炸开合并为纯几何
#   - 源实体批量删除 erase_entities(官方推荐 bulk 删除)
#   - 复制失败实体不删除; 出错整体回滚 abort_operation
#
# 用法:
#   方式一: 打开「控制面板」窗口 -> 点「开始合并」(选中范围或全模型)
#   方式二: 框选实体 -> 点工具栏「按材质合并」按钮
#
# 安装:
#   %APPDATA%\SketchUp\SketchUp 20xx\SketchUp\Plugins\
#   (macOS: ~/Library/Application Support/SketchUp 20xx/SketchUp/Plugins/)
#
# 兼容: SketchUp 2017 及以上(HtmlDialog 需 SU 2019+; 2017/2018 自动降级)
#==============================================================================

require 'sketchup.rb'

module WB
  module MaterialMerger

    PLUGIN_NAME    = '按材质合并'
    PLUGIN_VERSION = '2.7.1'

    # 调试输出开关(官方规范: 发布版必须关闭)
    DEBUG_MODE = false

    # 大工程预警阈值: 待合并的顶层组/组件数达到该值时先确认
    BIG_MODEL_THRESHOLD = 3000

    # 大任务阈值: 待合并实体数达到该值时走"进度弹窗/面板 + 异步分块"模式
    PROGRESS_DIALOG_THRESHOLD = 100

    # 用户主动取消(触发后整体回滚)
    class OperationCancelled < StandardError; end

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
    # 控制面板(常驻窗口): 「开始合并」按钮 + 取消按钮 + 进度条 + 状态区
    # 同时实现进度显示接口(update/cancelled?/show_result/close),
    # 面板打开时即作为大/小任务的进度载体; 关闭面板视为取消。
    #----------------------------------------------------------------------
    class ControlPanel
      PANEL_HTML = <<~HTML
        <style>
          body { font-family: 'Segoe UI', sans-serif; padding: 14px; background: #2b2b2b; color: #e8e8e8; margin: 0; }
          h3 { margin: 0 0 6px 0; font-size: 14px; font-weight: 500; }
          .hint { font-size: 11px; color: #999; margin-bottom: 10px; }
          .bar { width: 100%; height: 14px; background: #444; border-radius: 7px; overflow: hidden; }
          .fill { height: 100%; width: 0%; background: #4caf50; transition: width .15s; }
          .info { margin-top: 8px; font-size: 12px; color: #ccc; min-height: 16px; word-break: break-all; }
          .row { margin-top: 12px; display: flex; gap: 8px; }
          .btn { flex: 1; padding: 6px 0; border: none; border-radius: 4px; cursor: pointer; font-size: 13px; }
          .primary { background: #378add; color: #fff; }
          .primary:hover { background: #185FA5; }
          .ghost { background: #555; color: #ddd; }
          .ghost:hover { background: #6b6b6b; }
        </style>
        <h3>按材质合并</h3>
        <div class="hint">框选要合并的组/组件，或直接合并整个模型</div>
        <div class="bar"><div class="fill" id="fill"></div></div>
        <div class="info" id="info">就绪</div>
        <div class="row">
          <button class="btn primary" onclick="sketchup.startMerge()">开始合并</button>
          <button class="btn ghost" onclick="sketchup.cancel()">取消</button>
        </div>
        <div class="row">
          <button class="btn ghost" onclick="sketchup.purge()">清理未使用数据</button>
        </div>
        <div class="tip">关闭后重开：扩展程序 &gt; 按材质合并 &gt; 打开控制面板</div>
        <script>
          function setStatus(t) { document.getElementById('info').textContent = t; }
          function updateProgress(p, n) {
            document.getElementById('fill').style.width = p + '%';
            document.getElementById('info').textContent = p + '%  ' + n;
          }
        </script>
      HTML

      attr_reader :cancelled

      def initialize
        @cancelled = false
        @dialog = UI::HtmlDialog.new(
          dialog_title: '按材质合并',
          preferences_key: 'wb_material_merger.panel',
          width: 340, height: 248, min_width: 300, min_height: 210,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_html(PANEL_HTML)
        @dialog.add_action_callback('startMerge') { |_a, _p| WB::MaterialMerger.start_merge }
        @dialog.add_action_callback('cancel') { |_a, _p| @cancelled = true }
        @dialog.add_action_callback('purge') { |_a, _p| WB::MaterialMerger.purge_from_panel }
        begin
          @dialog.set_on_closed { @cancelled = true }
        rescue StandardError
          # 旧版本无 set_on_closed, 忽略
        end
        @dialog.show
      end

      def visible?
        return false unless @dialog
        @dialog.visible?
      rescue StandardError
        false
      end

      def show
        @dialog.show
      rescue StandardError
        nil
      end

      def cancelled?
        @cancelled
      end

      # --- 进度显示接口 ---
      def update(done, total, name)
        pct = (done * 100 / total).to_i
        execute("updateProgress(#{pct}, '#{WB::MaterialMerger.js_escape(name)}')")
      end

      def show_result(message)
        execute("setStatus('#{WB::MaterialMerger.js_escape(message)}')")
        @cancelled = false # 重置取消标志, 便于下次任务
      end

      def close
        # 面板常驻, 不做任何事(用户可手动关闭)
      end

      private

      def execute(script)
        @dialog.execute_script(script)
      rescue StandardError
        nil
      end
    end

    #----------------------------------------------------------------------
    # 进度显示(无面板时的替代): 弹窗/状态栏
    #   - 大任务: HtmlDialog 进度条 + 取消按钮
    #   - 小任务: 状态栏文字 + 每 20 组刷新视图
    #----------------------------------------------------------------------
    class ProgressDisplay
      PROGRESS_HTML = <<~HTML
        <style>
          body { font-family: 'Segoe UI', sans-serif; padding: 14px; background: #2b2b2b; color: #e8e8e8; margin: 0; }
          .bar { width: 100%; height: 16px; background: #444; border-radius: 8px; overflow: hidden; }
          .fill { height: 100%; width: 0%; background: #4caf50; transition: width .15s; }
          .info { margin-top: 10px; font-size: 12px; color: #bbb; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .btn { margin-top: 10px; padding: 4px 16px; background: #666; color: #fff; border: none; border-radius: 4px; cursor: pointer; }
          .btn:hover { background: #888; }
          .tip { margin-top: 10px; font-size: 11px; color: #777; }
        </style>
        <div class="bar"><div class="fill" id="fill"></div></div>
        <div class="info" id="info">0%</div>
        <button class="btn" onclick="sketchup.cancel()">取消</button>
        <script>
          function updateProgress(p, name) {
            document.getElementById('fill').style.width = p + '%';
            document.getElementById('info').textContent = p + '%  ' + name;
          }
        </script>
      HTML

      attr_reader :cancelled

      def initialize(model, total_entities)
        @model = model
        @cancelled = false
        @last_refresh = 0
        @dialog = nil
        @use_dialog = total_entities >= PROGRESS_DIALOG_THRESHOLD
        build_dialog if @use_dialog
      end

      def cancelled?
        @cancelled
      end

      def update(done, total, name)
        pct = (done * 100 / total).to_i
        if @use_dialog
          begin
            @dialog.execute_script("updateProgress(#{pct}, '#{WB::MaterialMerger.js_escape(name)}')") if @dialog
          rescue StandardError
            # 对话框可能被用户关闭, 降级为状态栏
            Sketchup.status_text = "按材质合并... #{pct}%"
          end
        else
          Sketchup.status_text = "按材质合并... #{pct}% (#{done}/#{total} 组)"
          if done - @last_refresh >= 20
            @last_refresh = done
            begin
              @model.active_view.refresh
            rescue StandardError
            end
          end
        end
      end

      def show_result(message)
        UI.messagebox(message, MB_OK)
      end

      def close
        if @dialog
          begin
            @dialog.close if @dialog.visible?
          rescue StandardError
          end
        end
        Sketchup.status_text = ''
      end

      private

      def build_dialog
        # SU 2019+ 才有 UI::HtmlDialog, 旧版本自动降级为状态栏模式
        unless defined?(UI::HtmlDialog)
          @use_dialog = false
          return
        end
        @dialog = UI::HtmlDialog.new(
          dialog_title: '按材质合并进度',
          preferences_key: 'wb_material_merger.progress',
          width: 340, height: 140, min_width: 300, min_height: 120,
          style: UI::HtmlDialog::STYLE_UTILITY
        )
        @dialog.set_html(PROGRESS_HTML)
        @dialog.add_action_callback('cancel') { |_a, _p| @cancelled = true }
        begin
          @dialog.set_on_closed { @cancelled = true }
        rescue StandardError
        end
        @dialog.show
      end
    end

    #----------------------------------------------------------------------
    # 异步分块合并器: 每块处理固定时间片内的"单个实体", 让出事件泵后再
    # 调度下一块(UI.start_timer 链式), 界面保持响应, 避免"未响应"卡死。
    # 关键: 分块粒度是实体级——即使一个材质桶内有几万~几十万个实体,
    # 也按时间片分批处理, 不会单块长时间占满主线程。
    # progress 为实现进度接口的对象(ControlPanel / ProgressDisplay)
    #----------------------------------------------------------------------
    class AsyncMergeRunner
      TIME_SLICE = 0.15 # 每块最大处理时长(秒)
      TIMER_GAP  = 0.02 # 块间调度间隔(秒)

      def initialize(model, targets, purge, progress)
        @model = model
        @purge = purge
        @progress = progress
        @bucket_list = WB::MaterialMerger.group_by_material(targets).values
        @total = @bucket_list.size
        @bucket_index = 0  # 当前桶
        @item_index = 0    # 当前桶内实体索引
        @done = 0          # 已完成的桶数(进度)
        @stats = { merged_groups: 0, removed: 0, kept_instances: 0 }
        # 当前桶的惰性状态
        @cur_new_group = nil
        @cur_name = nil
        @cur_material = nil
        @cur_failed = []
        @cur_kept = 0
      end

      def start
        @model.start_operation('按材质合并', true)
        step
      end

      private

      def step
        if @progress && @progress.cancelled?
          cancel
          return
        end
        deadline = Time.now + TIME_SLICE
        while @bucket_index < @total && Time.now < deadline
          ents = @bucket_list[@bucket_index]
          if ents.size < 2
            # 单实体桶: 无需合并, 直接推进进度
            @bucket_index += 1
            @done += 1
            @progress.update(@done, @total, WB::MaterialMerger.material_name(ents.first.material)) if @progress
            next
          end
          # 惰性初始化当前桶(首次进入才建组)
          if @cur_new_group.nil?
            @cur_material = ents.first.material
            @cur_name = WB::MaterialMerger.material_name(@cur_material)
            @cur_new_group = @model.entities.add_group
            @cur_new_group.name = "合并_#{@cur_name}"
            # 组材质: 面有独立材质优先显示面材质, 无独立材质的面继承组材质
            @cur_new_group.material = @cur_material unless @cur_material.nil?
            @cur_failed = []
            @cur_kept = 0
          end
          # 处理当前桶的单个实体(原子操作, 毫秒级)
          e = ents[@item_index]
          begin
            @cur_kept += 1 if WB::MaterialMerger.copy_entity_to_group(@model, @cur_new_group, e)
          rescue StandardError => ex
            puts "material_merger: 复制实体失败 #{ex.message}" if DEBUG_MODE
            @cur_failed << e
          end
          @item_index += 1
          # 当前桶处理完: 批量删除源实体 + 统计 + 进入下一桶
          if @item_index >= ents.size
            to_erase = ents - @cur_failed
            unless to_erase.empty?
              begin
                @model.entities.erase_entities(to_erase)
              rescue StandardError
                to_erase.each(&:erase!)
              end
            end
            @stats[:merged_groups]  += 1
            @stats[:removed]        += to_erase.size
            @stats[:kept_instances] += @cur_kept
            @bucket_index += 1
            @item_index = 0
            @done += 1
            @cur_new_group = nil
            @progress.update(@done, @total, @cur_name) if @progress
          end
        end
        if @bucket_index >= @total
          succeed
        else
          # 不在这里刷新视图: 大模型下每块一次全量重绘会非常卡,
          # 视图在用户旋转/操作时自然重绘, 完成时再统一刷新一次
          UI.start_timer(TIMER_GAP, false) { step }
        end
      rescue OperationCancelled
        cancel
      rescue StandardError => e
        fail_cleanup(e)
      end

      def succeed
        # 提示清理状态(同步 purge 一般 1-2s; 若定义极多可后续再分块)
        @progress.update(@total, @total, '正在清理未使用定义...') if @progress
        purged = @purge ? WB::MaterialMerger.purge_unused_definitions(@model) : 0
        @model.commit_operation
        refresh_ui
        WB::MaterialMerger.running = false
        if @progress
          @progress.show_result(
            "合并完成: 合并 #{@stats[:merged_groups]} 组, " \
            "移除 #{@stats[:removed]} 个, 保留实例 #{@stats[:kept_instances]} 个, " \
            "清理定义 #{purged} 个"
          )
          @progress.close
        end
      end

      def cancel
        abort_operation
        WB::MaterialMerger.running = false
        @progress.show_result('已取消, 本次操作已回滚。') if @progress
        @progress.close if @progress
      end

      def fail_cleanup(error)
        abort_operation
        WB::MaterialMerger.running = false
        @progress.show_result("出错, 本次操作已回滚: #{error.message}") if @progress
        @progress.close if @progress
      end

      def abort_operation
        begin
          @model.abort_operation
        rescue StandardError
        end
      end

      def refresh_ui
        begin
          @model.active_view.refresh
        rescue StandardError
        end
      end
    end

    #----------------------------------------------------------------------
    # 防重入标志(异步分块进行中)
    #----------------------------------------------------------------------
    def self.running?
      @running ? true : false
    end

    def self.running=(value)
      @running = value
    end

    #----------------------------------------------------------------------
    # 判断实体是否为可合并的容器(组 或 组件实例)
    #----------------------------------------------------------------------
    def self.mergable?(entity)
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    end

    #----------------------------------------------------------------------
    # 材质分组 key / 显示名
    #----------------------------------------------------------------------
    def self.material_key(material)
      material ? format('mat:%<id>d', id: material.entityID) : 'mat:<default>'
    end

    def self.material_name(material)
      material ? material.display_name : '默认材质'
    end

    #----------------------------------------------------------------------
    # 按材质分组(无材质归入"默认材质")
    #----------------------------------------------------------------------
    def self.group_by_material(targets)
      buckets = Hash.new { |h, k| h[k] = [] }
      targets.each { |e| buckets[material_key(e.material)] << e }
      buckets
    end

    #----------------------------------------------------------------------
    # 复制单个源实体到目标组(保持世界坐标):
    #   - 源组(Group)     -> 实例化其定义后炸开, 内核整块复制几何
    #   - 源组件实例      -> 保留为实例(共享定义, 最紧凑存储)
    # 返回 true = 保留为实例 / false = 炸开为几何; 失败抛异常
    #----------------------------------------------------------------------
    def self.copy_entity_to_group(model, new_group, e)
      if e.is_a?(Sketchup::Group)
        inst = new_group.entities.add_instance(e.definition, e.transformation)
        # explode 失败(返回 false)时撤销实例并抛错
        unless inst.explode
          inst.erase!
          raise StandardError, 'explode 失败'
        end
        false
      else # Sketchup::ComponentInstance
        inst = new_group.entities.add_instance(e.definition, e.transformation)
        inst.material = e.material if e.material
        inst.layer = e.layer if e.layer
        true
      end
    end

    #----------------------------------------------------------------------
    # 合并一个材质桶(同步版, 小任务用): 全部是同材质实体
    # 返回: [保留实例数, 复制失败实体数组](失败的不删除, 防数据丢失)
    #----------------------------------------------------------------------
    def self.merge_bucket(model, new_group, ents)
      kept_instances = 0
      failed = []
      ents.each do |e|
        begin
          kept_instances += 1 if copy_entity_to_group(model, new_group, e)
        rescue StandardError => ex
          puts "material_merger: 复制实体失败 #{ex.message}" if DEBUG_MODE
          failed << e
        end
      end
      [kept_instances, failed]
    end

    #----------------------------------------------------------------------
    # 同步合并(小任务用): 按材质分组并合并
    # progress 为实现进度接口的对象(ControlPanel / ProgressDisplay)
    #----------------------------------------------------------------------
    def self.merge_entities(model, targets, progress = nil)
      stats = { merged_groups: 0, removed: 0, kept_instances: 0 }

      buckets = group_by_material(targets)

      done = 0
      total = buckets.size
      buckets.each do |_key, ents|
        done += 1
        # 用户取消: 立即抛出, 由 run 统一回滚
        raise OperationCancelled if progress && progress.cancelled?

        next if ents.size < 2 # 单实体无需合并

        material = ents.first.material
        new_group = model.entities.add_group
        new_group.name = "合并_#{material_name(material)}"
        # 组材质: 面有独立材质则优先显示面材质, 无独立材质的面继承组材质
        new_group.material = material unless material.nil?

        kept, failed = merge_bucket(model, new_group, ents)

        # 批量删除成功复制的源实体(官方推荐 bulk erase)
        to_erase = ents - failed
        unless to_erase.empty?
          begin
            model.entities.erase_entities(to_erase)
          rescue StandardError
            to_erase.each(&:erase!)
          end
        end

        stats[:merged_groups]  += 1
        stats[:removed]        += to_erase.size
        stats[:kept_instances] += kept
        progress.update(done, total, material_name(material)) if progress
      end

      stats
    end

    #----------------------------------------------------------------------
    # 清理未使用的组件定义(无实例引用的定义)
    #----------------------------------------------------------------------
    def self.purge_unused_definitions(model)
      # 先收集再删除: 避免"迭代集合时修改集合"(官方社区反复警告的坑,
      # 会导致跳过/重复/异常); count_instances 查询与删除分离
      to_remove = []
      model.definitions.each do |d|
        next if d.count_instances.to_i > 0
        to_remove << d
      end
      count = 0
      to_remove.each do |d|
        begin
          model.definitions.remove(d)
          count += 1
        rescue StandardError
          # 特殊定义(如动画模型)可能不允许删除, 跳过即可
        end
      end
      count
    end

    #----------------------------------------------------------------------
    # 打开控制面板(常驻窗口)
    #----------------------------------------------------------------------
    def self.open_panel
      if @panel && @panel.visible?
        @panel.show # 已显示, 保持
      else
        @panel = ControlPanel.new
      end
    rescue StandardError => e
      UI.messagebox("打开控制面板失败: #{e.message}", MB_OK)
    end

    #----------------------------------------------------------------------
    # 面板「开始合并」按钮回调
    #----------------------------------------------------------------------
    def self.start_merge
      run
    end

    #----------------------------------------------------------------------
    # 清理未使用数据(面板按钮/菜单): 清理所有无实例引用的组件定义
    # 独立于合并流程; 需确认(官方 Data Loss 条款), 整体可回滚
    #----------------------------------------------------------------------
    def self.purge_from_panel
      model = Sketchup.active_model
      unless model
        UI.messagebox('没有打开的模型!')
        return
      end

      # 防重入: 与合并共用运行标志
      if running?
        UI.messagebox('已有任务正在进行(合并/清理), 请等待完成。', MB_OK)
        return
      end

      result = UI.messagebox(
        "将清理模型中所有【未被引用的组件定义】。\n" \
        "此操作不可逆, 建议先保存模型。\n\n" \
        '是否继续?',
        MB_YESNO
      )
      return unless result == 6 # YES

      @running = true
      model.start_operation('清理未使用定义', true)
      begin
        count = purge_unused_definitions(model)
      rescue StandardError => e
        begin
          model.abort_operation
        rescue StandardError
        end
        @running = false
        UI.messagebox("出错, 本次操作已回滚: #{e.message}", MB_OK)
        return
      end
      if count > 0
        model.commit_operation
      else
        # 无实际改动: abort 代替 commit, 不产生多余撤销步骤,
        # 也避免大模型下空操作提交引发的内部重算
        begin
          model.abort_operation
        rescue StandardError
        end
      end
      @running = false

      message = "清理完成: 移除了 #{count} 个未使用的组件定义。"
      if @panel && @panel.visible?
        @panel.show_result(message)
      else
        UI.messagebox(message, MB_OK)
      end
    end

    #----------------------------------------------------------------------
    # 主入口
    #----------------------------------------------------------------------
    def self.run
      model = Sketchup.active_model
      unless model
        UI.messagebox('没有打开的模型!')
        return
      end

      # 防重入: 异步分块任务进行中
      if running?
        UI.messagebox('已有合并任务正在进行, 请等待完成或点「取消」。', MB_OK)
        return
      end

      # 编辑态防护: 处于组/组件编辑时, 选中实体的变换是局部坐标,
      # 直接合并会导致位置错乱, 删除编辑路径内实体还可能触发崩溃/异常。
      # 提供"自动退出编辑并继续", 免去手动按 Esc。
      unless model.active_path.nil? || model.active_path.empty?
        proceed = UI.messagebox(
          '检测到正处于组/组件编辑状态(双击进入了组/组件内部)。\n' \
          "此时合并会导致位置错乱, 需要先退出编辑。\n\n" \
          '是否自动退出编辑并继续?',
          MB_YESNO
        )
        return unless proceed == 6 # YES

        begin
          model.close_active
        rescue StandardError
          UI.messagebox('自动退出编辑失败, 请按 Esc 或点击空白处手动退出后重试。', MB_OK)
          return
        end
        # 退出后二次校验
        unless model.active_path.nil? || model.active_path.empty?
          UI.messagebox('仍处于编辑状态, 请手动退出后重试。', MB_OK)
          return
        end
      end

      # 优先使用当前选中范围; 未选中则处理整个模型的顶层实体
      targets = []
      model.selection.each { |e| targets << e if mergable?(e) }
      scope_all = false
      if targets.empty?
        model.entities.each { |e| targets << e if mergable?(e) }
        scope_all = true
      end

      if targets.empty?
        UI.messagebox('模型中没有可合并的组或组件。', MB_OK)
        return
      end

      scope_text = scope_all ? '整个模型(全部顶层组/组件)' : '当前选中范围'

      # 大工程预警
      if targets.size >= BIG_MODEL_THRESHOLD
        proceed = UI.messagebox(
          "检测到 #{targets.size} 个待合并实体(规模较大)。\n" \
          '将采用分批执行, 期间界面保持可用, 可随时取消。\n\n' \
          '是否继续?',
          MB_YESNO
        )
        return unless proceed == 6 # YES
      end

      result = UI.messagebox(
        "将按材质合并 #{targets.size} 个实体。\n处理范围: #{scope_text}\n\n" \
        '是否同时清理未使用的组件定义?' \
        "\n(清理可进一步减小文件体积, 建议选择\"是\")",
        MB_YESNOCANCEL
      )
      return if result == 2 # Cancel
      purge = (result == 6) # YES

      @running = true

      # 进度载体: 面板打开则用面板, 否则用临时进度显示(弹窗/状态栏)
      progress = (@panel && @panel.visible?) ? @panel : ProgressDisplay.new(model, targets.size)

      if targets.size >= PROGRESS_DIALOG_THRESHOLD
        # 大任务: 异步分块 + 进度显示(界面不冻结, 可取消)
        @runner = AsyncMergeRunner.new(model, targets, purge, progress)
        @runner.start # 立即返回, 后续由 UI.start_timer 链式推进
        # 注意: @running 在 Runner 完成/取消/出错时复位
      else
        # 小任务: 同步执行(快, 无卡顿风险)
        model.start_operation('按材质合并', true)
        begin
          stats = merge_entities(model, targets, progress)
          purged = purge ? purge_unused_definitions(model) : 0
        rescue OperationCancelled
          begin
            model.abort_operation
          rescue StandardError
          end
          @running = false
          progress.show_result('已取消, 本次操作已回滚。') if progress
          progress.close if progress
          return
        rescue StandardError => e
          begin
            model.abort_operation
          rescue StandardError
          end
          @running = false
          progress.show_result("出错, 本次操作已回滚: #{e.message}") if progress
          progress.close if progress
          return
        end
        model.commit_operation
        begin
          model.active_view.refresh
        rescue StandardError
        end
        @running = false
        if progress
          progress.show_result(
            "合并完成: 合并 #{stats[:merged_groups]} 组, " \
            "移除 #{stats[:removed]} 个, 保留实例 #{stats[:kept_instances]} 个, " \
            "清理定义 #{purged} 个"
          )
          progress.close
        end
      end
    end

    #----------------------------------------------------------------------
    # 注册菜单与工具栏
    #----------------------------------------------------------------------
    def self.register
      unless @loaded
        @loaded = true

        # 菜单: 扩展程序 > 按材质合并
        menu = UI.menu('Extensions').add_submenu(PLUGIN_NAME)
        menu.add_item("打开控制面板...") { open_panel }
        menu.add_item("按材质合并...") { run }
        menu.add_item("清理未使用数据...") { purge_from_panel }

        # 工具栏: 「按材质合并」 + 「控制面板」(必须持有引用)
        @toolbar = UI::Toolbar.new(PLUGIN_NAME)
        cmd_merge = UI::Command.new("按材质合并") { run }
        cmd_merge.tooltip = '按材质合并(合并选中范围或整个模型)'
        cmd_merge.status_bar_text = '按材质把组/组件合并成一个组, 并可选清理未使用组件定义'
        cmd_merge.menu_text = '按材质合并...'
        @toolbar = @toolbar.add_item(cmd_merge)

        cmd_panel = UI::Command.new("打开面板") { open_panel }
        cmd_panel.tooltip = '打开按材质合并控制面板(关闭后可随时从这里重新打开)'
        cmd_panel.status_bar_text = '打开控制面板: 一键合并 + 任务状态显示 + 清理未使用数据'
        cmd_panel.menu_text = '打开控制面板...'
        @toolbar = @toolbar.add_item(cmd_panel)
        @toolbar.show
      end
    end

  end
end

#----------------------------------------------------------------------
# 加载入口(避免重复加载时重复注册)
#----------------------------------------------------------------------
unless file_loaded?(__FILE__)
  WB::MaterialMerger.register
end
file_loaded(__FILE__)
