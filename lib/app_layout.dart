/// 全局布局常量。
///
/// 单独放一个文件是为了避开循环导入：右上角的切换器由 `app_shell.dart`
/// 渲染，而 `command_console.dart` 的页头需要引用它的尺寸来留白。
library;

/// 右上角页面切换器的宽度（两个图标标签 + 轨道内边距）。
///
/// 与 `_GlassSectionSwitcher` 里的 `tabWidth * 2 + 轨道 padding * 2` 一致，
/// 改动那边时要一起改。
const double kSwitcherWidth = 129.0;

/// 切换器距屏幕上沿的间距
const double kSwitcherTopGap = 2.0;

/// 切换器距屏幕右沿的间距
const double kSwitcherRightGap = 16.0;

/// 页头为了避开浮在右上角的切换器，需要预留的右侧空白。
///
/// 10 是留给切换器与页头元素之间的呼吸间隙。
const double kHeaderRightInset = kSwitcherRightGap + kSwitcherWidth + 10;
