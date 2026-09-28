import 'dart:async';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_background.dart';
import 'app_layout.dart';
import 'app_settings.dart';
import 'command_console.dart';
import 'history.dart';
import 'quality_panel.dart';
import 'settings_page.dart';

/// 应用外壳：共享的动态背景 + 两个页面 + 右上角的液态玻璃切换器。
///
/// 用 [PageView] 而不是 `IndexedStack`：既能保留两页的状态（回到控制台时
/// 输入框内容和历史都还在），又自带切换过渡，左右滑动也能换页。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _pageTransition = Duration(milliseconds: 320);

  final _pageController = PageController();

  /// 两个页面共用同一份历史：设置页清空后，控制台列表会跟着重建。
  final _history = HistoryController();

  int _index = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_history.restore());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 落盘开关以设置为权威。这里只同步标志位——磁盘上旧存档的清理
    // 由设置页那次交互负责，启动时不该顺手删掉用户的数据。
    _history.persist = context.appSettings.persistHistory;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _history.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (index == _index) return;
    // 先更新索引让切换器立刻响应，翻页动画随后跟上
    setState(() => _index = index);
    _pageController.animateToPage(
      index,
      duration: _pageTransition,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return HistoryScope(controller: _history, child: _buildScaffold(context));
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      // 背景由 AppBackground 画；Scaffold 必须透明才能让背景图透出来
      backgroundColor: Colors.transparent,
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: AppBackground()),
          // 页面自己处理四边安全区；切换器单独定位到右上角，
          // 所以它不受 SafeArea 约束（位置由 top/right 显式算）
          SafeArea(
            child: PageView(
              controller: _pageController,
              // 手指滑动换页后同步索引，否则切换器的高亮会停在旧位置
              onPageChanged: (i) => setState(() => _index = i),
              children: const <Widget>[CommandConsolePage(), SettingsPage()],
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + kSwitcherTopGap,
            right: kSwitcherRightGap,
            child: _GlassSectionSwitcher(index: _index, onSelect: _go),
          ),
        ],
      ),
    );
  }
}

/// 右上角的页面切换器。
///
/// 这里没有用库里的 `GlassTabBar.inline`。它看起来正合适（胶囊玻璃轨道 +
/// 果冻指示器），但实测**完全渲染不出来**：它的玻璃轨道走
/// `AdaptiveGlass.grouped`，而该路径写死了 `useOwnLayer: false`，
/// 意味着必须继承祖先提供的玻璃层；它内部又是 `Row(children: ...)`
/// 这种要撑满父约束的布局，只有待在 Scaffold 的 appBar/bottomBar 槽位里
/// 才被正常约束。塞进 `Stack` 的 `Positioned` 之后就整体透明了。
///
/// 所以改用本项目里已经验证可见的 [GlassContainer] 拼一个同款：
/// 胶囊玻璃轨道 + 选中项的主题色淡染块。少了一点果冻回弹的物理感，
/// 但颜色、圆角、尺寸都与原来一致。
class _GlassSectionSwitcher extends StatelessWidget {
  const _GlassSectionSwitcher({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  /// 单个标签的尺寸。60×2 + 轨道左右 padding 4.5×2 = [kSwitcherWidth]
  static const tabWidth = 60.0;
  static const tabHeight = 45.0;

  /// 轨道内边距
  static const _trackPadding = 4.5;

  /// 只有图标——右上角空间有限，文字会把标题挤到没地方放。
  /// 名字放进语义标签，读屏用户仍能听出是哪个页签。
  static const _tabs = <(IconData, String)>[
    (Icons.terminal_rounded, '控制台'),
    (Icons.tune_rounded, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return QualityPanel(
      radius: 27,
      padding: const EdgeInsets.all(_trackPadding),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < _tabs.length; i++)
            _SwitcherTab(
              icon: _tabs[i].$1,
              semanticLabel: _tabs[i].$2,
              selected: i == index,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }
}

/// 切换器里的一个图标标签：选中时浮起一层主题色淡染，图标带缩放淡入。
class _SwitcherTab extends StatelessWidget {
  const _SwitcherTab({
    required this.icon,
    required this.semanticLabel,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final bool selected;
  final VoidCallback onTap;

  static const _duration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // 22.5 = 标签高度的一半（原本是个胶囊）；跟着全局圆角一起缩，
    // 缩小时与轨道的圆角才配得上
    final radius = context.radius(22.5);

    return Semantics(
      label: semanticLabel,
      button: true,
      selected: selected,
      child: Tooltip(
        message: semanticLabel,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          splashColor: palette.accent.withValues(alpha: 0.12),
          highlightColor: palette.accent.withValues(alpha: 0.06),
          child: AnimatedContainer(
            duration: _duration,
            curve: Curves.easeOutCubic,
            width: _GlassSectionSwitcher.tabWidth,
            height: _GlassSectionSwitcher.tabHeight,
            decoration: BoxDecoration(
              color: selected ? palette.accentHighlight : Colors.transparent,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: AnimatedSwitcher(
              duration: _duration,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.85, end: 1).animate(animation),
                  child: child,
                ),
              ),
              child: Icon(
                icon,
                // Key 随选中态变化：这样切换时图标会重播一次缩放淡入
                key: ValueKey<bool>(selected),
                size: 25.5,
                color: selected ? palette.accent : palette.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
