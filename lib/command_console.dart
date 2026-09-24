import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'src/rust/api/minecraft.dart' as mc;

const _kQuality = GlassQuality.standard;

/// 深色背景下的文字色阶（白灰混色，保证在近黑底色上的可读性）：
/// 主文本 → 次要文本 → 辅助/提示文本 → 弱提示。
const Color _textPrimary = Color(0xFFF2F5F8);
const Color _textSecondary = Color(0xFFC8D0D9);
const Color _textTertiary = Color(0xFFA3ADB8);
const Color _textMuted = Color(0xFF8B949F);

/// 补全列表中单项的高度（固定值，配合 `ListView.itemExtent` 让高亮项
/// 能被精确滚入可视区，也让入场错位动画的节奏可预测）
const double _kSuggestionExtent = 32;

/// 一条历史记录
class _HistoryEntry {
  /// 自增序号：作为列表项的 Key，使入场动画只在插入时播放一次，
  /// 后续滚动/重建不会重播；同时让重复执行同一指令的记录彼此独立。
  final int id;
  final String command;
  final bool success;
  final String message;
  const _HistoryEntry(this.id, this.command, this.success, this.message);
}

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

  /// "指令完整"状态的呼吸动画：徽章脉动与发送按钮光晕共用同一节奏，
  /// 使两者在同一拍上，不会各跳各的。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// 历史记录自增 id
  int _historySeq = 0;
  /// 已经播放过入场动画的记录 id。
  ///
  /// 列表项被回收后重建时不会再重播——否则往回滚动时会看到历史"重新浮现"。
  final Set<int> _enteredHistory = <int>{};

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

  final List<_HistoryEntry> _history = [];
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
    final target = (index * _kSuggestionExtent -
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

  Future<void> _execute() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    final r = await mc.execute(input: input);
    if (!mounted) return;
    setState(() {
      _history.insert(0, _HistoryEntry(_historySeq++, input, r.success, r.message));
    });
    GlassToast.show(
      context,
      message: r.message,
      type: r.success ? GlassToastType.success : GlassToastType.error,
      quality: _kQuality,
    );
    if (r.success) {
      _controller.clear();
      _analyzeNow();
    }
  }

  /// 点击左上角图标：显示软件信息与操作说明
  Future<void> _showAboutDialog() async {
    final count = _allCommands.isEmpty ? (await mc.listCommands()).length : _allCommands.length;
    if (!mounted) return;
    const version = '1.0.0'; // 与 pubspec.yaml / packaging\windows\installer.iss 保持一致

    await GlassDialog.show<void>(
      context: context,
      quality: _kQuality,
      maxWidth: 420,
      barrierDismissible: true,
      title: 'Minecraft 指令台',
      actions: [
        GlassDialogAction(
          label: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
        GlassDialogAction(
          label: '指令面板',
          isPrimary: true,
          onPressed: () {
            Navigator.of(context).pop();
            _showCommandPalette();
          },
        ),
      ],
      content: DefaultTextStyle(
        style: const TextStyle(color: _textSecondary, fontSize: 13, height: 1.45),
        child: SizedBox(
          height: 340,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Image.asset('assets/app_icon.png', width: 56, height: 56),
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
                    3, '补全列表实时过滤，点击候选项补齐；按 Tab 键（手机端点 Tab 按钮）可在候选之间循环切换'),
                const _StepRow(4, '参数错误时红色文字指出原因与位置，例如拼错的方块 / 物品 ID'),
                const _StepRow(5, '指令完整时徽章变为绿色的"指令完整"，按回车或点发送按钮执行'),
                const _StepRow(6, '执行成功弹绿色提示并写入历史记录；失败弹红色提示说明原因'),
                const _StepRow(7, '点右上角书本图标打开指令面板，可查看全部指令的用法，点击即填入输入框'),
                const _StepRow(8, '再次点击左上角图标，可随时打开本说明'),
                const SizedBox(height: 12),
                const Text(
                  '提示：指令面板中带 OP 标记的指令需要管理员权限。'
                  '本程序为指令语法校验与效果模拟器，不会连接真实游戏服务器。',
                  style: TextStyle(color: _textTertiary, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showCommandPalette() async {
    final cmds = _allCommands.isEmpty ? await mc.listCommands() : _allCommands;
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xE6101014),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '指令面板 · ${cmds.length} 条',
                style: const TextStyle(color: _textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: cmds.length,
                itemBuilder: (ctx, i) {
                  final c = cmds[i];
                  return GlassCard(
                    quality: _kQuality,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: InkWell(
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _controller.text = '${c.usage} ';
                        _controller.selection = TextSelection.collapsed(
                          offset: _controller.text.length,
                        );
                        _focusNode.requestFocus();
                        _analyzeNow();
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '/${c.name}',
                                  style: const TextStyle(
                                    color: Color(0xFF7EF0B2),
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                if (c.aliases.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '别名：${c.aliases.join(', ')}',
                                    style: const TextStyle(color: _textTertiary, fontSize: 11),
                                  ),
                                ],
                                const Spacer(),
                                if (c.opOnly)
                                  const _Pill(label: 'OP', color: Color(0x66FFB74D)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              c.usage,
                              style: const TextStyle(
                                color: _textSecondary,
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              c.description,
                              style: const TextStyle(color: _textTertiary, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          // 背景光斑
          const _BackgroundGlow(),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                Expanded(child: _buildHistory()),
                _buildBottomPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          InkWell(
            onTap: _showAboutDialog,
            borderRadius: BorderRadius.circular(14),
            splashColor: Colors.white12,
            highlightColor: Colors.white10,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Image.asset('assets/app_icon.png', width: 34, height: 34),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Minecraft CommandLine',
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Rust 引擎驱动',
                  style: TextStyle(color: _textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
          GlassButton(
            icon: const Icon(Icons.menu_book, color: Colors.white, size: 22),
            onTap: _showCommandPalette,
            width: 46,
            height: 46,
            quality: _kQuality,
          ),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, color: Colors.white24, size: 56),
            const SizedBox(height: 12),
            const Text(
              '执行过的指令会显示在这里',
              style: TextStyle(color: _textTertiary, fontSize: 13),
            ),
            const SizedBox(height: 6),
            const Text(
              '试试输入 /gamemode cre',
              style: TextStyle(color: _textTertiary, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _history.length,
      itemBuilder: (ctx, i) {
        final h = _history[i];
        // Key 用自增 id：新记录插入时它在 index 0 上"首次出现"而播放入场动画，
        // 已有记录随 index 下移时 element/State 被复用，动画不会重播。
        //
        // `_enteredHistory.add` 返回 true 表示这条记录第一次被构建，只有它才播动画；
        // 列表项被回收后重建时会得到 false，直接静止显示。
        return _HistoryCard(
          key: ValueKey<int>(h.id),
          entry: h,
          animate: _enteredHistory.add(h.id),
        );
      },
    );
  }

  /// 状态徽章：蓝→绿的颜色/图标/文字过渡，完整时外加一圈向外扩散的呼吸光环。
  ///
  /// 光环用 `Positioned.fill` 撑在徽章下方，`_pulse` 从 0→1 时它同步放大、
  /// 同时淡出，形成"心跳"观感；非完整状态下它的透明度恒为 0，等于不存在。
  Widget _buildStatusBadge() {
    final accent = _complete ? const Color(0xFF7EF0B2) : const Color(0xFF80DEEA);
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
          color: _complete ? const Color(0x337EF0B2) : const Color(0x3380DEEA),
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
    return GlassContainer(
      quality: _kQuality,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      shape: const LiquidRoundedSuperellipse(borderRadius: 24),
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
                  style: const TextStyle(color: _textSecondary, fontSize: 12),
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
              style: const TextStyle(
                color: _textTertiary,
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
                const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF8A80), size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _errors.first.message,
                    style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
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
                color: const Color(0x14101418),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
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
            children: [
              Expanded(
                child: Focus(
                  // 桌面端：拦截 Tab 键做补全（否则会被焦点遍历吞掉）
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.tab) {
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
                    quality: _kQuality,
                    placeholder: '输入 / 开头的指令…',
                    placeholderStyle: const TextStyle(color: _textMuted, fontSize: 14),
                    textStyle: const TextStyle(
                      color: _textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                    onSubmitted: (_) => _execute(),
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
                quality: _kQuality,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.keyboard_tab,
                      size: 16,
                      color: _suggestions.isNotEmpty ? const Color(0xFF80DEEA) : _textMuted,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'Tab',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _suggestions.isNotEmpty ? _textPrimary : _textMuted,
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
                                color: const Color(0xFF7EF0B2)
                                    .withValues(alpha: 0.30 * (0.35 + 0.65 * v)),
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
                      begin: _textTertiary,
                      end: _complete ? const Color(0xFF7EF0B2) : _textTertiary,
                    ),
                    builder: (context, color, _) =>
                        Icon(Icons.send_rounded, color: color, size: 22),
                  ),
                  onTap: _execute,
                  width: 48,
                  height: 48,
                  quality: _kQuality,
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
        style: const TextStyle(
          color: Color(0xFF7EF0B2),
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
              style: const TextStyle(color: _textTertiary, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: _textSecondary, fontSize: 12),
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
              color: const Color(0x337EF0B2),
              borderRadius: BorderRadius.circular(5),
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: const TextStyle(
                color: Color(0xFF7EF0B2),
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

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ─────────────────────────── 背景：动态流光 ───────────────────────────

/// 动态背景：若干色相光斑沿弧线缓慢漂移、呼吸，另有一道斜向光带周期性掠过。
///
/// 性能取舍：
/// - 动画只发生在**绘制阶段**（[CustomPainter] 直接监听 [AnimationController]，
///   通过 `super(repaint: ...)` 驱动），不触发 build / layout；
/// - 外层套 [RepaintBoundary]，把重绘限制在这一层，上层的历史列表、
///   玻璃面板不会跟着每帧重画；
/// - 扫光在画布外一段距离时就存在，配合 clipRect 让进出场自然。
class _BackgroundGlow extends StatefulWidget {
  const _BackgroundGlow();

  @override
  State<_BackgroundGlow> createState() => _BackgroundGlowState();
}

class _BackgroundGlowState extends State<_BackgroundGlow>
    with SingleTickerProviderStateMixin {
  /// 一个完整循环的时长。取值偏长（36s）以保证"流光"是缓慢渗染而非闪烁。
  static const _period = Duration(seconds: 36);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _period,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 系统开启"减弱动态效果"时退化为静态光斑（也顺带省电）
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Positioned.fill(
      child: RepaintBoundary(
        child: IgnorePointer(
          child: CustomPaint(
            painter: _GlowPainter(
              animation:
                  reduceMotion ? const AlwaysStoppedAnimation<double>(0) : _controller,
            ),
            willChange: true,
          ),
        ),
      ),
    );
  }
}

/// 一个光斑的静态描述：渐变、归一化中心、半径系数、漂移幅度与相位。
class _Blob {
  _Blob({
    required this.gradient,
    required this.centerX,
    required this.centerY,
    required this.radius,
    required this.driftX,
    required this.driftY,
    required this.phase,
  });

  final RadialGradient gradient;
  /// 中心坐标，按画布宽/高归一化（允许 <0 或 >1，让光斑大部分留在画布外）
  final double centerX;
  final double centerY;
  /// 半径系数，乘以画布短边
  final double radius;
  /// 单方向漂移幅度，分别乘以画布宽/高
  final double driftX;
  final double driftY;
  /// 相位 0..1，用于错开各光斑的节奏
  final double phase;
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.animation}) : super(repaint: animation);

  final Animation<double> animation;

  static final List<_Blob> _blobs = [
    _Blob(
      gradient: const RadialGradient(
        colors: [Color(0x2A10B981), Color(0x0010B981)],
      ),
      centerX: 0.88,
      centerY: -0.06,
      radius: 0.74,
      driftX: 0.06,
      driftY: 0.05,
      phase: 0.00,
    ),
    _Blob(
      gradient: const RadialGradient(
        colors: [Color(0x223B82F6), Color(0x003B82F6)],
      ),
      centerX: -0.14,
      centerY: 0.94,
      radius: 0.86,
      driftX: 0.08,
      driftY: 0.06,
      phase: 0.37,
    ),
    _Blob(
      gradient: const RadialGradient(
        colors: [Color(0x1C8B5CF6), Color(0x008B5CF6)],
      ),
      centerX: 1.04,
      centerY: 0.54,
      radius: 0.66,
      driftX: 0.05,
      driftY: 0.09,
      phase: 0.68,
    ),
    _Blob(
      gradient: const RadialGradient(
        colors: [Color(0x1822D3EE), Color(0x0022D3EE)],
      ),
      centerX: 0.32,
      centerY: 1.10,
      radius: 0.58,
      driftX: 0.10,
      driftY: 0.04,
      phase: 0.19,
    ),
  ];

  /// 斜向扫光的渐变（沿光带法线方向由透明→亮→透明）
  static const _sweepGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      Color(0x0000E5A0),
      Color(0x1400E5A0),
      Color(0x1F7DF9D0),
      Color(0x1400E5A0),
      Color(0x0000E5A0),
    ],
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = animation.value;
    final shortest = size.shortestSide;

    canvas.clipRect(Offset.zero & size);
    for (final b in _blobs) {
      // 两个不同频率的正弦叠加，避免所有光斑整齐划一地摆动
      final dx = math.sin((t + b.phase) * 2 * math.pi) * b.driftX * size.width;
      final dy = math.cos((t * 0.74 + b.phase) * 2 * math.pi) * b.driftY * size.height;
      final breath = 0.90 + 0.10 * math.sin((t * 1.37 + b.phase) * 2 * math.pi);

      final center = Offset(
        b.centerX * size.width + dx,
        b.centerY * size.height + dy,
      );
      final radius = b.radius * shortest * breath;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = b.gradient.createShader(
            Rect.fromCircle(center: center, radius: radius),
          ),
      );
    }

    _paintSweep(canvas, size, t);
  }

  /// 一道低透明度的斜向光带：每个循环扫两次，其余时间留白形成间歇节奏。
  void _paintSweep(Canvas canvas, Size size, double t) {
    const travelPortion = 0.55; // 单次扫光占循环的比例
    final progress = (t * 2) % 1.0;
    if (progress > travelPortion) return;
    final travel = progress / travelPortion; // 0..1

    final bandWidth = size.width * 0.34;
    final diagonal = math.sqrt(size.width * size.width + size.height * size.height);
    final x = -bandWidth + travel * (size.width + bandWidth * 2);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-0.42); // 斜向 ≈ -24°
    final rect = Rect.fromCenter(
      center: Offset(x - size.width / 2, 0),
      width: bandWidth,
      height: diagonal * 1.2,
    );
    canvas.drawRect(rect, Paint()..shader = _sweepGradient.createShader(rect));
    canvas.restore();
  }

  /// 重绘完全由 `repaint: animation` 驱动；此处只需处理"换了一个动画源"
  /// （例如系统切换了减弱动态效果）时的重绘。
  @override
  bool shouldRepaint(_GlowPainter oldDelegate) =>
      oldDelegate.animation != animation;
}

// ─────────────────────────── 动效组件 ───────────────────────────

/// 系统是否要求"减弱动态效果"。
///
/// 用 `platformDispatcher` 而不是 `MediaQuery`：这样在 `initState` 里就能取到，
/// 不必等到 `didChangeDependencies`，组件可以保持无状态依赖。
bool _reduceMotion() => WidgetsBinding
    .instance.platformDispatcher.accessibilityFeatures.disableAnimations;

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

  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

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
          color: active ? const Color(0x227EF0B2) : Colors.transparent,
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
                color: const Color(0xFF7EF0B2).withValues(alpha: active ? 1 : 0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Text(
              suggestion.label,
              style: TextStyle(
                color: active ? const Color(0xFF7EF0B2) : const Color(0xFFB2EBF2),
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                suggestion.detail,
                style: const TextStyle(color: _textTertiary, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.keyboard_tab,
              size: 13,
              color: active ? const Color(0xFF7EF0B2) : _textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// 历史记录卡片：新记录插入时淡入，并自上而下滑入。
class _HistoryCard extends StatefulWidget {
  const _HistoryCard({
    super.key,
    required this.entry,
    required this.animate,
  });

  final _HistoryEntry entry;
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

  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

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
    return GlassCard(
      quality: _kQuality,
      margin: const EdgeInsets.symmetric(vertical: 5),
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
                color: h.success ? const Color(0xFF7EF0B2) : const Color(0xFFFF8A80),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      h.command,
                      style: const TextStyle(
                        color: _textPrimary,
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
                        color: h.success ? _textTertiary : const Color(0xFFFFAB91),
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
