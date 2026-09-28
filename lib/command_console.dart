import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// `context.palette` / `context.history` 这两个扩展分别定义在
// app_settings.dart 与 history.dart 里，必须导入才能用。
import 'app_layout.dart';
import 'app_settings.dart';
import 'glass.dart';
import 'history.dart';
import 'quality_panel.dart';
import 'src/rust/api/minecraft.dart' as mc;

/// 补全列表中单项的高度（固定值，配合 `ListView.itemExtent` 让高亮项
/// 能被精确滚入可视区，也让入场错位动画的节奏可预测）
const double _kSuggestionExtent = 32;

/// 新记录从输入框飞进列表顶部的时长。
const Duration _kFlyDuration = Duration(milliseconds: 460);

/// 飞入动画的曲线：起步快、落位慢，做成非线性。
///
/// 列表让出的空位与飞行中的替身卡片共用这一条曲线，两边才会同时到位。
const Curve _kFlyCurve = Curves.easeOutCubic;

/// 页面里所有颜色都取自 `context.palette`（见 `app_palette.dart`），
/// 不再有硬编码色值——换主题色、切明暗模式时整页一起变。
/// 历史记录同理，读 `context.history`。

class CommandConsolePage extends StatefulWidget {
  const CommandConsolePage({super.key});

  @override
  State<CommandConsolePage> createState() => _CommandConsolePageState();
}

class _CommandConsolePageState extends State<CommandConsolePage>
    with TickerProviderStateMixin {
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

  /// 输入框。新执行的指令从它所在的位置起飞（见 [_startFlyIn]）。
  final _inputKey = GlobalKey();

  /// 飞入期间那份"离屏"的真卡片。
  ///
  /// 它只参与布局、不参与绘制（`Offstage`），两个用处：让列表按它的自然
  /// 高度留出空位，以及量出它的位置与尺寸给飞行的替身卡片当落点。
  final _flyingCardKey = GlobalKey();

  /// 飞入动画：0 = 还停在输入框位置，1 = 已经落到列表顶部。
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: _kFlyDuration,
  );

  /// 正在飞入的那条记录（null = 没有动画在跑）
  HistoryRecord? _flying;

  /// 起飞高度：输入框上边缘在页面坐标系里的 y
  double? _flyStartY;

  /// 落点：列表顶部那张卡片（含内外边距）在页面坐标系里的矩形；量到之前为 null
  Rect? _flyDest;

  /// 刚落地的记录 id。
  ///
  /// 飞入动画已经替它做过一次"登场"，列表接手后不能再播一遍入场动画，
  /// 否则会看到卡片落地后又淡入下滑一次。
  int? _landedId;

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
    // 动画一停就把替身卡片摘掉，换成列表里的真卡片
    _fly.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finishFlyIn();
    });
    _analyzeNow();
    mc.listCommands().then((cmds) {
      if (mounted) setState(() => _allCommands = cmds);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pulse.dispose();
    _fly.dispose();
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
    // 先给手感反馈：视觉上的飞入动画要 460ms 才落地，震动是第一时间的回应
    _vibrate(success: r.success);
    // 交给共享控制器：它会通知两个页面，并按设置决定是否落盘
    context.history.add(input, r.success, r.message);
    // 这条新记录从输入框飞进列表顶部
    _startFlyIn();
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

  /// 执行指令后震一下：成功轻、失败重一档——失败更需要被注意到。
  ///
  /// 只在移动端调。桌面端没有振动马达，走平台通道只会抛
  /// MissingPluginException；另外 haptic 本身就是系统的"触感反馈"，
  /// 用户在系统里关掉后自然不会响，所以不必再给一个应用内开关。
  void _vibrate({required bool success}) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        break;
      default:
        return;
    }
    final feedback = success
        ? HapticFeedback.lightImpact()
        : HapticFeedback.mediumImpact();
    // 反馈失败不该影响指令执行，异常吞掉
    unawaited(
      feedback.catchError((Object _) {
        // 忽略：拿不到振动能力就算了
      }),
    );
  }

  /// 新记录从输入框飞进列表顶部。
  ///
  /// 做法不是"先把卡片插进去再挪位置"——那样列表会先跳一下。而是：
  ///
  /// 1. 新记录照常进列表，但列表第一条先渲染成 [_FlyingSlot]：一段 0 高的
  ///    空位，外加一份 `Offstage` 的真卡片。空位不占高度，因此这一帧的布局
  ///    与插入前完全一致，不会闪；
  /// 2. 这一帧结束后量出那份离屏卡片的位置与自然高度——那就是落点；
  /// 3. 空位与替身卡片一起按 [_kFlyCurve] 推进：空位涨高，把下面的记录顶着
  ///    往下平移；替身卡片从输入框上边缘升到落点；
  /// 4. 动画结束换成列表里的真卡片：高度和位置都是量出来的，切换看不出来。
  ///
  /// 列表不在顶部时不飞——落点在可视区之外，替身卡片会飞到页头上方去。这时
  /// 直接退化成原来的入场动画（判定放在 [_launchFlyIn] 里：第一次执行指令时
  /// 列表刚由空态变成有内容，这里还拿不到滚动控制器）。
  void _startFlyIn() {
    final history = context.history;
    final page = context.findRenderObject() as RenderBox?;
    final inputBox = _inputKey.currentContext?.findRenderObject() as RenderBox?;
    if (history.isEmpty ||
        page == null ||
        inputBox == null ||
        !inputBox.hasSize ||
        _reduceMotion()) {
      return;
    }

    // 上一条还没落地就又执行了一条：先把上一次结掉（它的卡片此刻已经排到
    // 第二位，按满高画出来即可），再让新的一条起飞。
    final aborted = _flying;
    _fly.stop();
    setState(() {
      if (aborted != null) _landedId = aborted.id;
      _flying = history.items.first;
      _flyStartY = page.globalToLocal(inputBox.localToGlobal(Offset.zero)).dy;
      _flyDest = null;
    });
    _fly.value = 0;
    // 等这一帧把离屏卡片布局完，才量得到落点
    WidgetsBinding.instance.addPostFrameCallback((_) => _launchFlyIn());
  }

  /// 量出落点，然后起飞。
  void _launchFlyIn() {
    if (!mounted || _flying == null) return;
    final page = context.findRenderObject() as RenderBox?;
    final card =
        _flyingCardKey.currentContext?.findRenderObject() as RenderBox?;
    // 列表已经滚下去了、或者量不到卡片（极端布局）：放弃飞入，退回入场动画
    final noLandingSpot =
        !_scrollController.hasClients ||
        _scrollController.offset > 0.5 ||
        page == null ||
        card == null ||
        !card.hasSize ||
        card.size.isEmpty;
    if (noLandingSpot) {
      _finishFlyIn(landed: false);
      return;
    }
    setState(() {
      _flyDest =
          page.globalToLocal(card.localToGlobal(Offset.zero)) & card.size;
    });
    _fly.forward();
  }

  /// 摘掉替身卡片，把列表里的真卡片放出来。
  ///
  /// [landed] 为 false 表示这次飞入没飞成：真卡片按普通入场动画登场，
  /// 所以不记 [_landedId]（那条记录还有一次入场动画的名额没用）。
  void _finishFlyIn({bool landed = true}) {
    if (!mounted || _flying == null) return;
    final id = _flying!.id;
    setState(() {
      if (landed) _landedId = id;
      _flying = null;
      _flyStartY = null;
      _flyDest = null;
    });
  }

  /// 点击左上角图标：显示软件信息与操作说明
  Future<void> _showAboutDialog() async {
    final count = _allCommands.isEmpty
        ? (await mc.listCommands()).length
        : _allCommands.length;
    if (!mounted) return;
    const version =
        '2.0.0'; // 与 pubspec.yaml / packaging\windows\installer.iss 保持一致

    // 这里没有用库里的 `GlassDialog.show`：它内部固定走 `showCupertinoDialog`，
    // 而那条路由会给整个弹窗套一层淡入（Opacity）。玻璃的 backdrop 采样一旦被
    // Opacity 层包住就不生效——低档（半透明衬底）的弹窗于是"先露面、约 0.1 秒后
    // 才变模糊"，等转场结束、Opacity 层被移除才补上；极低档本来就不该有玻璃，
    // 也跟着糊一下。
    //
    // 所以自己起一个路由：barrier 照常淡入（它不碰玻璃），弹窗本体一帧到位，
    // 外壳交给 [_AboutDialog]（按当前档位决定是玻璃还是纯色块）。
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭说明',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      // 弹窗本体不做淡入/缩放：外层一旦包上 Opacity 或 Transform，玻璃的
      // backdrop 采样就会被打乱（_HistoryCard 里那条注释讲的是同一个坑）
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (dialogContext, _, _) => _AboutDialog(
        version: version,
        commandCount: count,
        onDismiss: () => Navigator.of(dialogContext).pop(),
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
      child: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              _buildHeader(),
              Expanded(child: _buildHistory()),
              _buildBottomPanel(),
            ],
          ),
          // 飞入途中的替身卡片：叠在整页之上，才能盖着输入面板一路升到列表顶部
          _buildFlyingCard(),
        ],
      ),
    );
  }

  /// 飞入动画里的替身卡片；没有动画在跑时是个零尺寸占位。
  ///
  /// 位置只走布局（`Positioned`），尺寸在飞行过程中不变——不对玻璃做
  /// Transform / Opacity，那会打乱 backdrop 采样（见 [_HistoryCard] 的说明）。
  Widget _buildFlyingCard() {
    final entry = _flying;
    final dest = _flyDest;
    final startY = _flyStartY;
    if (entry == null || dest == null || startY == null) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _fly,
      // 替身卡片作为 child 传进来：每帧只重建外面这层 Positioned，
      // 里面的玻璃卡片不跟着重建（一帧几十次重建玻璃面板是白烧性能）
      child: IgnorePointer(child: _GhostCard(entry: entry)),
      builder: (context, child) {
        final t = _kFlyCurve.transform(_fly.value);
        // 起点贴着输入框上边缘，水平方向已经与落点对齐，所以整段动画就是
        // 一次"向上升起 + 落位"；终点与列表里真卡片的矩形重合。
        final from = startY - dest.height;
        return Positioned.fromRect(
          rect: Rect.fromLTWH(
            dest.left,
            from + (dest.top - from) * t,
            dest.width,
            dest.height,
          ),
          child: child!,
        );
      },
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
            borderRadius: BorderRadius.circular(context.radius(14)),
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
              '试试输入 /effect clear @p',
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

        // 正在飞入的那条：列表里先摆一段会涨高的空位，外加一份离屏布局的
        // 真卡片（`Offstage` 不绘制，只用来量落点见 [_launchFlyIn]）。
        // 空位涨高把下面的记录顶着往下平移，替身卡片则飞来填进这段空位。
        if (i == 0 && _flying != null && h.id == _flying!.id) {
          return _FlyingSlot(
            animation: _fly,
            height: _flyDest?.height ?? 0,
            child: Offstage(
              offstage: true,
              child: _HistoryCard(
                key: _flyingCardKey,
                entry: h,
                animate: false,
              ),
            ),
          );
        }

        // Key 用自增 id：新记录插入时它在 index 0 上"首次出现"而播放入场动画，
        // 已有记录随 index 下移时 element/State 被复用，动画不会重播。
        //
        // `takeEntranceAnimation` 第一次问返回 true，之后都是 false——
        // 列表项被回收后重建时直接静止显示，不会"重新浮现"。
        return _HistoryCard(
          key: ValueKey<int>(h.id),
          entry: h,
          // 刚飞进来的那条已经飞过了，不能再播一次入场动画（见 [_landedId]）
          animate: history.takeEntranceAnimation(h.id) && h.id != _landedId,
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
                      borderRadius: BorderRadius.circular(context.radius(8)),
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
          borderRadius: BorderRadius.circular(context.radius(8)),
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
      // 这个面板里嵌着一块可滚动的补全列表。premium 的玻璃要自己开一块捕获
      // 图层，**在滚动上下文里它和内容会失去同步**：玻璃的背景/边框留在旧位置，
      // 里面的文字已经在动了，看上去就是"文字没动、面板动了"，过一会儿才跳
      // 回来。库文档把它列为已知的 Impeller 限制，项目里滚动列表中的卡片也是
      // 这么处理的（见 quality_panel.dart 的 capQuality）。
      // 标准档走的是实时着色器，不抓屏，滚动时也稳。
      capQuality: GlassQuality.standard,
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
              // 候选不再限制条数（物品有上千条），可视区多高由设置里的
              // 「提示框高度」决定；列表本身可滚动，露不下的部分滚出来。
              constraints: BoxConstraints(
                maxHeight: context.appSettings.suggestionPanelHeight,
              ),
              margin: const EdgeInsets.only(top: 8),
              // 候选项入场是"从下方滑进来"，首尾两项的滑动会越出这块圆角容器
              // （Container 默认不裁剪），看上去就成了文字压在边框上。裁进圆角里。
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: context.palette.isDark
                    ? const Color(0x14101418)
                    : const Color(0x0A000000),
                borderRadius: BorderRadius.circular(context.radius(12)),
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
                    // 飞入动画从输入框的位置起飞
                    key: _inputKey,
                    controller: _controller,
                    focusNode: _focusNode,
                    // 开自己的图层：premium 需要有几何信息可捕获，见 glass.dart
                    quality: context.glassQuality,
                    useOwnLayer: true,
                    // 形状照库的默认（圆角 10），只是跟着全局圆角系数缩放
                    shape: LiquidRoundedRectangle(
                      borderRadius: context.radius(10),
                    ),
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
                    // 内容折行时自动长高；上限由设置里的「输入框最大高度」
                    // 决定，长到头之后改为在输入框内部滚动
                    minLines: 1,
                    maxLines: context.appSettings.inputMaxLines,
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
                // 关掉"按住不放就朝手指方向拉长"的那段果冻手感：premium 档下
                // 玻璃的边是烘在缓存纹理里的，缩放那层纹理会把边框拉糊——
                // 按住 Tab 按钮往下拖时看到的边框错位就是它。拖动拉伸关掉后，
                // 按压放大（iOS 26 那颗按钮的"胀一下"）还在。
                stretch: 0,
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
                  // 同上：不要拖动拉伸，否则按住往下拖会把玻璃边框拉错位
                  stretch: 0,
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
              borderRadius: BorderRadius.circular(context.radius(5)),
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

// ─────────────────────── 关于弹窗 ───────────────────────

/// 「软件信息与操作说明」弹窗。
///
/// 内容与之前交给库的 `GlassDialog` 时一致，只是外壳换成了项目自己的
/// [QualityPanel]：极低档在这里会退化成纯色块（跟页面其它地方一样不碰玻璃），
/// 其余档位照常出玻璃。
class _AboutDialog extends StatelessWidget {
  const _AboutDialog({
    required this.version,
    required this.commandCount,
    required this.onDismiss,
  });

  final String version;
  final int commandCount;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // 弹窗里的玻璃封顶在标准档，理由见 glass.dart 的 dialogQualityFor
    final quality = dialogQualityFor(context.appSettings.glassQualityMode);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: QualityPanel(
            radius: 24,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            capQuality: quality,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Minecraft 指令台',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                // 内容区高度写死：高度随内容浮动的话，玻璃面板每帧都要重新量边
                SizedBox(
                  height: 340,
                  child: SingleChildScrollView(
                    child: DefaultTextStyle(
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 13,
                        height: 1.45,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Center(
                            child: Image.asset(
                              'assets/app_icon.png',
                              width: 56,
                              height: 56,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const _SectionTitle('软件信息'),
                          _InfoRow('版本', version),
                          _InfoRow('内置指令', '$commandCount 条'),
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
                              color: palette.textTertiary,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _AboutDialogAction(onPressed: onDismiss, quality: quality),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 关于弹窗底部的确认按钮。
///
/// 玻璃档用库的 [GlassButton]；极低档换成一块纯色，跟面板一样不碰玻璃。
class _AboutDialogAction extends StatelessWidget {
  const _AboutDialogAction({required this.onPressed, required this.quality});

  final VoidCallback onPressed;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = context.radius(14);
    final label = Text(
      '知道了',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: palette.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    );

    if (!context.glassEnabled) {
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(radius),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accentHighlight,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: label,
          ),
        ),
      );
    }

    return GlassButton.custom(
      onTap: onPressed,
      height: 44,
      quality: quality,
      useOwnLayer: true,
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      glowColor: palette.accent.withValues(alpha: 0.30),
      // 关掉"按住拖动会拉长"的果冻手感：premium 档下玻璃的边是烘在缓存纹理
      // 里的，缩放那层纹理会把边框拉糊（库注释里承认的 Impeller 限制）
      stretch: 0,
      child: label,
    );
  }
}

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
    final radius = context.radius(8);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: AnimatedContainer(
        duration: _transition,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: active ? context.palette.accentHighlight : Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
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
///
/// 如果它走的是飞入动画（见 [_startFlyIn]），[animate] 会传 false ——
/// 那一次"登场"已经由替身卡片飞完了，落地后再播一遍就重复了。
class _HistoryCard extends StatefulWidget {
  const _HistoryCard({super.key, required this.entry, required this.animate});

  final HistoryRecord entry;

  /// 是否播放入场动画（只在该记录首次出现、且不是飞入进来的那条时为 true）
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
    // 关键：动画只能包在卡片的**内容**上，不能包住面板（玻璃）本身。
    //
    // 玻璃效果依赖 BackdropFilter 与共享的合成层，外层再叠一层
    // Opacity（FadeTransition）/ Transform（SlideTransition）会打乱它的
    // backdrop 采样，构建时直接断言失败（红屏）。
    // 而历史列表在执行第一条指令之前是空的，所以只有"执行指令后"才会
    // 第一次构建出这张卡片——故障时机正好吻合。
    //
    // 飞入动画里那张替身卡片守的是同一条规矩：只改位置（走布局），
    // 不对玻璃做 Transform / Opacity（见 [_GhostCard]）。
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
          child: _HistoryEntryBody(entry: widget.entry),
        ),
      ),
    );
  }
}

/// 一条历史记录的内容（状态图标 + 指令原文 + 执行结果）。
///
/// 抽出来是为了让列表里的真卡片与飞入途中的替身卡片用同一份内容：
/// 两者尺寸一致，落位时的替换才看不出来。
class _HistoryEntryBody extends StatelessWidget {
  const _HistoryEntryBody({required this.entry});

  final HistoryRecord entry;

  @override
  Widget build(BuildContext context) {
    final h = entry;
    final stamp = h.createdAt;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          h.success ? Icons.check_circle : Icons.error,
          color: h.success ? context.palette.accent : context.palette.errorIcon,
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      h.command,
                      style: TextStyle(
                        color: context.palette.textPrimary,
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 时间靠右对齐，与指令原文同一行；老存档没有时间就不占位
                  if (stamp != null) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      formatHistoryTime(stamp, DateTime.now()),
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 11,
                        // 等宽数字：列表滚动/刷新时读数不会左右抖
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ],
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
    );
  }
}

/// 飞入期间列表最前面那段"让位"的空位。
///
/// 只涨高、不绘制任何东西：由它把下面的记录顶着往下平移。涨高与卡片飞行
/// 共用 [_kFlyCurve]，所以两边同时到位。
///
/// [child] 是一份离屏布局的真卡片（`Offstage`，不绘制），只用来量落点。
class _FlyingSlot extends StatelessWidget {
  const _FlyingSlot({
    required this.animation,
    required this.height,
    required this.child,
  });

  final Animation<double> animation;

  /// 落点卡片的高度；量到之前传 0，空位就先不撑开
  final double height;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      // child 作为参数传进来，每帧只重建这层薄壳，里面的玻璃卡片不重建
      child: child,
      builder: (context, child) => Column(
        mainAxisSize: MainAxisSize.min,
        // 撑满宽度：里面的离屏卡片要与列表里的真卡片拿到同样的宽度约束，
        // 量出来的高度才一致
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(height: height * _kFlyCurve.transform(animation.value)),
          child!,
        ],
      ),
    );
  }
}

/// 飞入途中那张"替身"卡片。
///
/// 结构与列表里的真卡片完全一致（同样的外边距、圆角、内边距与内容），
/// 落位那一刻换成真卡片，位置与尺寸都对得上，看不出替换。
///
/// 飞行中只改它的位置（`Positioned` 走布局），尺寸保持不变——不对玻璃做
/// Transform / Opacity，那会打乱 backdrop 采样（见 [_HistoryCard] 的说明）。
class _GhostCard extends StatelessWidget {
  const _GhostCard({required this.entry});

  final HistoryRecord entry;

  @override
  Widget build(BuildContext context) {
    return QualityPanel(
      radius: 12,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(vertical: 5),
      // 与列表里的卡片同一档：都走实时着色器，替换的那一帧不会有没画出来的空档
      capQuality: GlassQuality.standard,
      // 光球是绕着面板跑的装饰，飞行途中加进来只是多一层动画
      showOrbit: false,
      child: _HistoryEntryBody(entry: entry),
    );
  }
}
