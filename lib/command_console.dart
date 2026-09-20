import 'dart:async';

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

/// 一条历史记录
class _HistoryEntry {
  final String command;
  final bool success;
  final String message;
  const _HistoryEntry(this.command, this.success, this.message);
}

class CommandConsolePage extends StatefulWidget {
  const CommandConsolePage({super.key});

  @override
  State<CommandConsolePage> createState() => _CommandConsolePageState();
}

class _CommandConsolePageState extends State<CommandConsolePage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

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
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
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
    _applySuggestion(_suggestions[next], appendSpace: false);
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
      _history.insert(0, _HistoryEntry(input, r.success, r.message));
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
        return GlassCard(
          quality: _kQuality,
          margin: const EdgeInsets.symmetric(vertical: 5),
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
                    Text(
                      h.message,
                      style: TextStyle(
                        color: h.success ? _textSecondary : const Color(0xFFFFAB91),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _complete
                      ? const Color(0x337EF0B2)
                      : const Color(0x3380DEEA),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _complete ? Icons.check : Icons.tips_and_updates_outlined,
                      size: 12,
                      color: _complete ? const Color(0xFF7EF0B2) : const Color(0xFF80DEEA),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _complete ? '指令完整' : '光标提示',
                      style: TextStyle(
                        fontSize: 11,
                        color: _complete ? const Color(0xFF7EF0B2) : const Color(0xFF80DEEA),
                      ),
                    ),
                  ],
                ),
              ),
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
              constraints: const BoxConstraints(maxHeight: 180),
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: const Color(0x14101418),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _suggestions.length,
                itemBuilder: (ctx, i) {
                  final s = _suggestions[i];
                  final active = i == _activeTabIndex;
                  return InkWell(
                    onTap: () => _applySuggestion(s),
                    child: Container(
                      decoration: BoxDecoration(
                        color: active ? const Color(0x227EF0B2) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        children: [
                          Text(
                            s.label,
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
                              s.detail,
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
              GlassButton(
                icon: Icon(
                  Icons.send_rounded,
                  color: _complete ? const Color(0xFF7EF0B2) : _textTertiary,
                  size: 22,
                ),
                onTap: _execute,
                width: 48,
                height: 48,
                quality: _kQuality,
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

class _BackgroundGlow extends StatelessWidget {
  const _BackgroundGlow();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -80,
            right: -60,
            child: _blob(const Color(0x2210B981), 320),
          ),
          Positioned(
            bottom: 60,
            left: -100,
            child: _blob(const Color(0x1A3B82F6), 380),
          ),
          Positioned(
            top: 240,
            right: -120,
            child: _blob(const Color(0x148B5CF6), 300),
          ),
        ],
      ),
    );
  }

  Widget _blob(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}
