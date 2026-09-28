import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// `context.palette` / `context.history` 这两个扩展分别定义在
// app_settings.dart 与 history.dart 里，必须导入才能用。
import 'app_layout.dart';
import 'app_settings.dart';
import 'history.dart';
import 'quality_panel.dart';
import 'src/rust/api/minecraft.dart' as mc;

/// 补全列表中单项的高度（固定值，配合 `ListView.itemExtent` 让高亮项
/// 能被精确滚入可视区，也让入场错位动画的节奏可预测）
const double _kSuggestionExtent = 32;

/// 页面里所有颜色都取自 `context.palette`（见 `app_palette.dart`），
/// 不再有硬编码色值——换主题色、切明暗模式时整页一起变。
/// 历史记录同理，读 `context.history`。

class CommandConsolePage extends StatefulWidget {
  const CommandConsolePage({super.key});

  @override
  State<CommandConsolePage> createState() => _CommandConsolePageState();
}

class _CommandConsolePageState extends State<CommandConsolePage>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  /// 补全列表的滚动控制器：Tab 循环时用它把高亮项滚进可视区
  final _suggestionScroll = ScrollController();

  /// 底部面板的范围。
  ///
  /// 点面板内部的控件（补全候选、Tab 按钮）时不该收起键盘：这些操作结束后
  /// 会 requestFocus 回到输入框，若中间先 unfocus 一次，手机上输入法就会
  /// 先隐后现地闪一下。
  final _panelKey = GlobalKey();

  /// "指令完整"状态的呼吸动画：徽章脉动与发送按钮光晕共用同一节奏，
  /// 使两者在同一拍上，不会各跳各的。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  Timer? _debounce;
  List<mc.Suggestion> _suggestions = [];
  List<mc.SyntaxError> _errors = [];
  String _hint = '输入指令，例如 /give';
  String _usage = '';
  bool _complete = false;
  int _replaceStart = 0;

  /// Tab 补全过程：当前循环到的候选下标（-1 表示未开始）
  int _tabIndex = -1;

  /// 标记由代码（而非用户键入）触发的文本变更，用于区分是否重置循环下标
  bool _programmaticEdit = false;

  List<mc.CommandInfo> _allCommands = [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _analyzeNow();
    mc.listCommands().then((cmds) {
      if (mounted) setState(() => _allCommands = cmds);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pulse.dispose();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _suggestionScroll.dispose();
    super.dispose();
  }

  int get _cursor {
    final sel = _controller.selection;
    if (sel.isValid && sel.baseOffset >= 0) return sel.baseOffset;
    return _controller.text.length;
  }

  void _onTextChanged() {
    // 用户手动输入时重置 Tab 循环下标；代码填充（Tab 循环）时保留
    if (!_programmaticEdit) {
      _tabIndex = -1;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 60), _analyzeNow);
  }

  /// 当前被 Tab 高亮的候选下标（越界时返回 -1）
  int get _activeTabIndex =>
      (_tabIndex >= 0 && _tabIndex < _suggestions.length) ? _tabIndex : -1;

  /// Tab 键 / Tab 按钮：用下一个候选项补全当前 token（循环切换，不补空格）
  void _tabComplete() {
    if (_suggestions.isEmpty) return;
    final next = (_tabIndex + 1) % _suggestions.length;
    setState(() => _tabIndex = next);
    _ensureSuggestionVisible(next);
    _applySuggestion(_suggestions[next], appendSpace: false);
  }

  /// 把 Tab 循环到的候选项滚入可视区。
  ///
  /// 列表项高度固定（[_kSuggestionExtent]），所以无需测量即可算出目标偏移：
  /// 让该项大致居中，再夹在合法滚动范围内。
  void _ensureSuggestionVisible(int index) {
    if (!_suggestionScroll.hasClients) return;
    final position = _suggestionScroll.position;
    final target =
        (index * _kSuggestionExtent -
                (position.viewportDimension - _kSuggestionExtent) / 2)
            .clamp(0.0, position.maxScrollExtent);
    if ((position.pixels - target).abs() < 0.5) return;
    _suggestionScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  /// 让呼吸动画与 [_complete] 保持一致：完整时循环脉动，其余时候归零停表。
  void _syncPulse() {
    if (_complete) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating || _pulse.value != 0) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  Future<void> _analyzeNow() async {
    final r = await mc.analyze(input: _controller.text, cursor: _cursor);
    if (!mounted) return;
    setState(() {
      _suggestions = r.suggestions;
      _errors = r.errors;
      _hint = r.hint.isEmpty ? '无更多参数' : r.hint;
      _usage = r.usage;
      _complete = r.complete;
      _replaceStart = r.replaceStart;
    });
    _syncPulse();
  }

  /// 用建议替换光标所在的 token
  ///
  /// [appendSpace] 为 null 时按建议自身的提示决定是否补空格；
  /// Tab 循环补全传 false，以便继续在同一 token 内切换候选项。
  void _applySuggestion(mc.Suggestion s, {bool? appendSpace}) {
    final text = _controller.text;
    final start = _replaceStart.clamp(0, text.length).toInt();
    // 找到当前 token 的结尾
    var end = start;
    while (end < text.length && text.codeUnitAt(end) != 0x20) {
      end++;
    }
    final insert = s.insert + ((appendSpace ?? s.appendSpace) ? ' ' : '');
    final newText = text.replaceRange(start, end, insert);
    _programmaticEdit = true;
    _controller
      ..text = newText
      ..selection = TextSelection.collapsed(offset: start + insert.length);
    _programmaticEdit = false;
    _focusNode.requestFocus();
    _analyzeNow();
  }

  /// 点输入框以外的地方收起键盘，但**点底部面板里的控件不收起**。
  ///
  /// `GlassTextField` 默认的 `onTapOutside` 会直接 unfocus。补全候选和 Tab
  /// 按钮都在输入框之外，点它们会先关掉输入法、再被 `requestFocus` 拉回来，
  /// 手机上表现为输入法闪一下（中间还伴随一次布局跳动）。
  void _onTapOutside(PointerDownEvent event) {
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final local = box.globalToLocal(event.position);
      if ((Offset.zero & box.size).contains(local)) return;
    }
    _focusNode.unfocus();
  }

  Future<void> _execute() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    final r = await mc.execute(input: input);
    if (!mounted) return;
    // 交给共享控制器：它会通知两个页面，并按设置决定是否落盘
    context.history.add(input, r.success, r.message);
    GlassToast.show(
      context,
      message: r.message,
      type: r.success ? GlassToastType.success : GlassToastType.error,
      quality: context.glassQuality,
    );
    if (r.success) {
      _controller.clear();
      _analyzeNow();
    }
  }

  /// 点击左上角图标：显示软件信息与操作说明
  Future<void> _showAboutDialog() async {
    final count = _allCommands.isEmpty
        ? (await mc.listCommands()).length
        : _allCommands.length;
    if (!mounted) return;
    const version =
        '2.0.0'; // 与 pubspec.yaml / packaging\windows\installer.iss 保持一致

    await GlassDialog.show<void>(
      context: context,
      quality: context.glassQuality,
      maxWidth: 420,
      barrierDismissible: true,
      title: 'Minecraft 指令台',
      actions: [
        GlassDialogAction(
          label: '知道了',
          isPrimary: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      content: DefaultTextStyle(
        style: TextStyle(
          color: context.palette.textSecondary,
          fontSize: 13,
          height: 1.45,
        ),
        child: SizedBox(
          height: 340,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Image.asset(
                    'assets/app_icon.png',
                    width: 56,
                    height: 56,
                  ),
                ),
                const SizedBox(height: 10),
                const _SectionTitle('软件信息'),
                const _InfoRow('版本', version),
                _InfoRow('内置指令', '$count 条'),
                const _InfoRow('支持平台', 'Windows / Android'),
                const SizedBox(height: 14),
                const _SectionTitle('软件操作'),
                const _StepRow(1, '输入以 / 开头的指令，例如 /give @a diamond 64'),
                const _StepRow(2, '打字时下方蓝色徽章显示"光标提示"，告诉你当前该填什么参数'),
                const _StepRow(
                  3,
                  '补全列表实时过滤，点击候选项补齐；按 Tab 键（手机端点 Tab 按钮）可在候选之间循环切换',
                ),
                const _StepRow(4, '参数错误时红色文字指出原因与位置，例如拼错的方块 / 物品 ID'),
                const _StepRow(5, '指令完整时徽章变为绿色的"指令完整"，按回车或点发送按钮执行'),
                const _StepRow(6, '执行成功弹绿色提示并写入历史记录；失败弹红色提示说明原因'),
                const _StepRow(7, '在「设置 → 指令手册」里打开指令面板，可查看全部指令的用法，点任意一条即复制'),
                const _StepRow(8, '再次点击左上角图标，可随时打开本说明'),
                const SizedBox(height: 12),
                Text(
                  '提示：指令面板中带 OP 标记的指令需要管理员权限。'
                  '本程序为指令语法校验与效果模拟器，不会连接真实游戏服务器。',
                  style: TextStyle(
                    color: context.palette.textTertiary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 动态背景（含自定义图片与流光）已经由 AppShell 统一提供，
    // 这里只负责三层内容：标题 → 历史 → 输入面板。
    // bottom 交给外壳处理——底部是浮动的玻璃导航栏。
    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          _buildHeader(),
          Expanded(child: _buildHistory()),
          _buildBottomPanel(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final palette = context.palette;
    return Padding(
      // 右侧留出浮在右上角的玻璃切换器：它是叠在页面之上的，
      // 不扣掉这块宽度，书本按钮和标题就会被胶囊压住
      padding: const EdgeInsets.fromLTRB(20, 8, kHeaderRightInset, 6),
      child: Row(
        children: <Widget>[
          InkWell(
            onTap: _showAboutDialog,
            borderRadius: BorderRadius.circular(14),
            splashColor: palette.accent.withValues(alpha: 0.10),
            highlightColor: palette.accent.withValues(alpha: 0.06),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Image.asset('assets/app_icon.png', width: 30, height: 30),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Minecraft CommandLine',
                  // 右上角被切换器占了位置，窄屏上允许标题省略
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textPrimary,
                    // 比原来的 19px 小一档：页头这一行要同时容纳
                    // 图标、标题、书本按钮和右上角的切换器
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Rust 引擎驱动',
                  style: TextStyle(color: palette.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          // 指令面板的入口已经移到设置页（页头这一行要给右上角的
          // 玻璃切换器让位，放不下第四个元素）
        ],
      ),
    );
  }

  Widget _buildHistory() {
    final palette = context.palette;
    final history = context.history;

    if (history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.history, color: palette.faintIcon, size: 56),
            const SizedBox(height: 12),
            Text(
              '执行过的指令会显示在这里',
              style: TextStyle(color: palette.textTertiary, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              '试试输入 /gamemode cre',
              style: TextStyle(color: palette.textTertiary, fontSize: 13),
            ),
          ],
        ),
      );
    }

    final items = history.items;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final h = items[i];
        // Key 用自增 id：新记录插入时它在 index 0 上"首次出现"而播放入场动画，
        // 已有记录随 index 下移时 element/State 被复用，动画不会重播。
        //
        // `takeEntranceAnimation` 第一次问返回 true，之后都是 false——
        // 列表项被回收后重建时直接静止显示，不会"重新浮现"。
        return _HistoryCard(
          key: ValueKey<int>(h.id),
          entry: h,
          animate: history.takeEntranceAnimation(h.id),
        );
      },
    );
  }

  /// 状态徽章：蓝→绿的颜色/图标/文字过渡，完整时外加一圈向外扩散的呼吸光环。
  ///
  /// 光环用 `Positioned.fill` 撑在徽章下方，`_pulse` 从 0→1 时它同步放大、
  /// 同时淡出，形成"心跳"观感；非完整状态下它的透明度恒为 0，等于不存在。
  Widget _buildStatusBadge() {
    final accent = _complete
        ? context.palette.accent
        : context.palette.accentSoft;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final v = _complete ? _pulse.value : 0.0;
        return Stack(
          alignment: Alignment.center,
          // 光环会放大到 1.22 倍并超出身位，不裁剪才能完整呼吸
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Transform.scale(
                  scale: 1 + 0.22 * v,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: accent.withValues(
                          alpha: _complete ? 0.45 * (1 - v) : 0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _complete
              ? context.palette.accentTint
              : context.palette.accentTint,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
                  child: child,
                ),
              ),
              child: Icon(
                _complete ? Icons.check : Icons.tips_and_updates_outlined,
                key: ValueKey<bool>(_complete),
                size: 12,
                color: accent,
              ),
            ),
            const SizedBox(width: 4),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              style: TextStyle(fontSize: 11, color: accent),
              child: Text(_complete ? '指令完整' : '光标提示'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return QualityPanel(
      key: _panelKey,
      radius: 24,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 光标提示 + 用法
          Row(
            children: [
              _buildStatusBadge(),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _hint,
                  style: TextStyle(
                    color: context.palette.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (_usage.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _usage,
              style: TextStyle(
                color: context.palette.textTertiary,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // 语法错误
          if (_errors.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: context.palette.errorIcon,
                  size: 15,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _errors.first.message,
                    style: TextStyle(
                      color: context.palette.errorIcon,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          // 补全建议
          if (_suggestions.isNotEmpty)
            Container(
              // 候选不再限制条数（物品有上千条），这里给一个更高的可视区，
              // 列表本身可滚动。
              constraints: const BoxConstraints(maxHeight: 224),
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: context.palette.isDark
                    ? const Color(0x14101418)
                    : const Color(0x0A000000),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: context.palette.textMuted.withValues(alpha: 0.18),
                ),
              ),
              child: ListView.builder(
                controller: _suggestionScroll,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                // 固定单项高度：既保证 [_ensureSuggestionVisible] 的偏移计算准确，
                // 也让入场动画的错位节奏稳定。
                itemExtent: _kSuggestionExtent,
                // 候选项以 label 作为 Key。打字导致列表内容变化时，
                // 仍然存在的候选项会被复用（不重播入场动画），只有新出现的才淡入。
                findChildIndexCallback: (key) {
                  final label = (key as ValueKey<String>).value;
                  final i = _suggestions.indexWhere((s) => s.label == label);
                  return i == -1 ? null : i;
                },
                itemCount: _suggestions.length,
                itemBuilder: (ctx, i) {
                  final s = _suggestions[i];
                  return _StaggerIn(
                    key: ValueKey<String>(s.label),
                    index: i,
                    child: _SuggestionTile(
                      suggestion: s,
                      active: i == _activeTabIndex,
                      onTap: () => _applySuggestion(s),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 10),
          // 输入行
          Row(
            // 输入框折行长高时，两个按钮贴底而不是被拉到中间
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Focus(
                  // 桌面端：拦截 Tab 键做补全（否则会被焦点遍历吞掉）
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.tab) {
                      // 无候选时不拦截，交还给系统做焦点切换
                      if (_suggestions.isEmpty) return KeyEventResult.ignored;
                      _tabComplete();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: GlassTextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    // 开自己的图层：premium 需要有几何信息可捕获，见 glass.dart
                    quality: context.glassQuality,
                    useOwnLayer: true,
                    placeholder: '输入 / 开头的指令…',
                    placeholderStyle: TextStyle(
                      color: context.palette.textMuted,
                      fontSize: 14,
                    ),
                    textStyle: TextStyle(
                      color: context.palette.textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                    // 内容折行时自动长高，最多 5 行，再多就在内部滚动
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    // 用 send 而不是 newline：回车执行指令，而不是插入换行
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _execute(),
                    onTapOutside: _onTapOutside,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 手机端：Tab 补全按钮（无候选时禁用）
              GlassButton.custom(
                onTap: _tabComplete,
                enabled: _suggestions.isNotEmpty,
                width: 56,
                height: 48,
                quality: context.glassQuality,
                useOwnLayer: true,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.keyboard_tab,
                      size: 16,
                      color: _suggestions.isNotEmpty
                          ? context.palette.accentSoft
                          : context.palette.textMuted,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'Tab',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _suggestions.isNotEmpty
                            ? context.palette.textPrimary
                            : context.palette.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 指令完整时，按钮外圈有一层随呼吸节奏起伏的绿色光晕
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final v = _complete ? _pulse.value : 0.0;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: _complete
                          ? [
                              BoxShadow(
                                color: context.palette.accent.withValues(
                                  alpha: 0.30 * (0.35 + 0.65 * v),
                                ),
                                blurRadius: 12 + 14 * v,
                                spreadRadius: 0.5 + 2 * v,
                              ),
                            ]
                          : const <BoxShadow>[],
                    ),
                    child: child,
                  );
                },
                child: GlassButton(
                  icon: TweenAnimationBuilder<Color?>(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    // 必须用 ColorTween：泛型 Tween<Color> 靠动态的 `+ - *`
                    // 做插值，而 Color 不支持这些运算，动画中间帧会抛
                    // "Cannot lerp between ..."。ColorTween 走 Color.lerp。
                    tween: ColorTween(
                      begin: context.palette.textTertiary,
                      end: _complete
                          ? context.palette.accent
                          : context.palette.textTertiary,
                    ),
                    builder: (context, color, _) =>
                        Icon(Icons.send_rounded, color: color, size: 22),
                  ),
                  onTap: _execute,
                  width: 48,
                  height: 48,
                  quality: context.glassQuality,
                  useOwnLayer: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 分组标题
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          color: context.palette.accent,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 信息行（标签 + 值）
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Text(
              label,
              style: TextStyle(
                color: context.palette.textTertiary,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 操作步骤行（序号 + 说明）
class _StepRow extends StatelessWidget {
  final int index;
  final String text;
  const _StepRow(this.index, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              color: context.palette.accentTint,
              borderRadius: BorderRadius.circular(5),
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: TextStyle(
                color: context.palette.accent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

// OP 标记的 _Pill 已经跟指令面板一起搬到 command_palette.dart

// ─────────────────────────── 动效组件 ───────────────────────────

/// 系统是否要求"减弱动态效果"。
///
/// 用 `platformDispatcher` 而不是 `MediaQuery`：这样在 `initState` 里就能取到，
/// 不必等到 `didChangeDependencies`，组件可以保持无状态依赖。
bool _reduceMotion() => WidgetsBinding
    .instance
    .platformDispatcher
    .accessibilityFeatures
    .disableAnimations;

/// 一次性入场：淡入 + 轻微上滑，并按 [index] 依次延迟形成错位节奏。
class _StaggerIn extends StatefulWidget {
  const _StaggerIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<_StaggerIn>
    with SingleTickerProviderStateMixin {
  /// 每项比前一项晚这么多入场；最多累计到第 8 项，末项不会久等
  static const _step = Duration(milliseconds: 26);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    if (_reduceMotion()) {
      _controller.value = 1;
      return;
    }
    Future<void>.delayed(_step * widget.index.clamp(0, 8), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.35),
          end: Offset.zero,
        ).animate(_curve),
        child: widget.child,
      ),
    );
  }
}

/// 一条补全候选：高亮态用颜色过渡衔接，左侧指示条从外侧滑入。
class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.suggestion,
    required this.active,
    required this.onTap,
  });

  final mc.Suggestion suggestion;
  final bool active;
  final VoidCallback onTap;

  static const _transition = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: _transition,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: active ? context.palette.accentHighlight : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            // 横滑指示条：从左侧 -4px 滑回原位，同时由透明渐显
            AnimatedContainer(
              duration: _transition,
              curve: Curves.easeOutCubic,
              width: 3,
              height: 16,
              transform: Matrix4.translationValues(active ? 0 : -4, 0, 0),
              transformAlignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.palette.accent.withValues(alpha: active ? 1 : 0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Text(
              suggestion.label,
              style: TextStyle(
                color: active ? context.palette.accent : context.palette.accent,
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                suggestion.detail,
                style: TextStyle(
                  color: context.palette.textTertiary,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.keyboard_tab,
              size: 13,
              color: active
                  ? context.palette.accent
                  : context.palette.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// 历史记录卡片：新记录插入时淡入，并自上而下滑入。
class _HistoryCard extends StatefulWidget {
  const _HistoryCard({super.key, required this.entry, required this.animate});

  final HistoryRecord entry;

  /// 是否播放入场动画（只在该记录首次出现时为 true）
  final bool animate;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  );

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    if (!widget.animate || _reduceMotion()) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.entry;
    // 关键：动画只能包在卡片的**内容**上，不能包住 [GlassCard] 本身。
    //
    // 玻璃效果依赖 BackdropFilter 与共享的合成层，外层再叠一层
    // Opacity（FadeTransition）/ Transform（SlideTransition）会打乱它的
    // backdrop 采样，构建时直接断言失败（红屏）。
    // 而历史列表在执行第一条指令之前是空的，所以只有"执行指令后"才会
    // 第一次构建出这张卡片——故障时机正好吻合。
    return QualityPanel(
      radius: 12,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(vertical: 5),
      // 列表卡片封顶在标准档：premium 在滚动容器里会出现背景发黑、
      // 内容跑到面板外、约 0.2 秒后才跳回来的故障（官方承认的限制）
      capQuality: GlassQuality.standard,
      child: FadeTransition(
        opacity: _curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.25),
            end: Offset.zero,
          ).animate(_curve),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                h.success ? Icons.check_circle : Icons.error,
                color: h.success
                    ? context.palette.accent
                    : context.palette.errorIcon,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      h.command,
                      style: TextStyle(
                        color: context.palette.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // 执行结果用"旁白"字体：斜体、色调更淡、行距略松，
                    // 与上面等宽正体的指令原文形成对照。
                    Text(
                      h.message,
                      style: TextStyle(
                        color: h.success
                            ? context.palette.textTertiary
                            : context.palette.errorText,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        height: 1.5,
                        letterSpacing: 0.15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
