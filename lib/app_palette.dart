import 'package:flutter/material.dart';

/// 调色板里的一个可选主题色。
class AccentOption {
  const AccentOption(this.id, this.name, this.color);

  /// 持久化用的稳定标识（不要改，改了老用户的设置会丢）
  final String id;

  /// 设置页展示的名字
  final String name;
  final Color color;
}

/// 内置调色板。
///
/// 取值都偏向高亮度、低饱和的"霓虹感"，这样叠在近黑底色上是发光，
/// 放到浅色底上也不会糊成一片。
const List<AccentOption> kAccents = <AccentOption>[
  AccentOption('emerald', '翡翠', Color(0xFF7EF0B2)),
  AccentOption('mint', '薄荷', Color(0xFF6EE7D0)),
  AccentOption('cyan', '青蓝', Color(0xFF80DEEA)),
  AccentOption('sky', '晴空', Color(0xFF7CC4FF)),
  AccentOption('indigo', '靛蓝', Color(0xFF9DB2FF)),
  AccentOption('violet', '紫罗兰', Color(0xFFC4A7FF)),
  AccentOption('pink', '桃粉', Color(0xFFFFA6D5)),
  AccentOption('rose', '玫瑰', Color(0xFFFF9DB0)),
  AccentOption('orange', '橘橙', Color(0xFFFFB07E)),
  AccentOption('amber', '琥珀', Color(0xFFFFD27E)),
  AccentOption('lime', '青柠', Color(0xFFD3F07E)),
  AccentOption('slate', '石墨', Color(0xFFB9C2CE)),
];

/// 深色组的主题色，主要给浅色模式用。
///
/// [kAccents] 那组的取值偏"发光"——明度高、饱和低，叠在近黑底上是霓虹感，
/// 但放到浅色底上就会糊、对比度也不够。这一组把明度压到 0.30-0.55、
/// 饱和度提到 0.6-0.9：白底上是清晰浓郁的深色，深色底上则是沉稳的暗调，
/// 两种模式都能用，只是观感不同。
const List<AccentOption> kDeepAccents = <AccentOption>[
  AccentOption('deepEmerald', '深翡翠', Color(0xFF0E9F6E)),
  AccentOption('deepTeal', '深青碧', Color(0xFF0F766E)),
  AccentOption('deepBlue', '深靛蓝', Color(0xFF1D4ED8)),
  AccentOption('deepIndigo', '深紫蓝', Color(0xFF4338CA)),
  AccentOption('deepViolet', '深紫罗兰', Color(0xFF7C3AED)),
  AccentOption('deepPink', '深玫粉', Color(0xFFBE185D)),
  AccentOption('deepOrange', '深橘', Color(0xFFC2410C)),
  AccentOption('deepAmber', '深琥珀', Color(0xFFB45309)),
  AccentOption('deepGreen', '深松绿', Color(0xFF15803D)),
];

/// 全部可选主题色（亮色组 + 深色组）。
///
/// 查找与遍历一律走它，免得某处只查了 [kAccents]，把深色组当成失效 id。
final List<AccentOption> kAllAccents = <AccentOption>[
  ...kAccents,
  ...kDeepAccents,
];

/// 按 id 取主题色；id 失效（例如降级后配置残留）时回落到第一个。
AccentOption accentById(String id) =>
    kAllAccents.firstWhere((a) => a.id == id, orElse: () => kAccents.first);

/// 当前生效的一整套语义色。
///
/// 页面里所有颜色都从这里取（`context.palette.xxx`），因此换主题色、
/// 切明暗模式时全界面自动跟着变——不需要各自去监听设置。
///
/// 明暗两套色阶是分别调过的：深色下用"白灰混色"保证在近黑底上的可读性，
/// 浅色下换成同明度关系的冷灰，避免直接反色导致的脏感。
class AppPalette {
  const AppPalette({required this.accent, required this.isDark});

  /// 当前主题色
  final Color accent;
  final bool isDark;

  // ─────────────────────────── 主题色派生 ───────────────────────────

  /// 主题色的柔和版，用于"光标提示"这类次级状态。
  ///
  /// 与 [accent] 同色相但更暗更淡，所以绿色主题下是"深绿提示 + 亮绿确认"，
  /// 换成紫色主题也仍然能区分出主次。
  Color get accentSoft {
    final hsl = HSLColor.fromColor(accent);
    // 偏移方向跟主题色自身的明度走：本来就亮（>0.5）的往下压，
    // 本来就暗的往上提。
    //
    // 原来是无条件压暗 0.16，加了深色组之后就出问题了——深色主题色的
    // 明度本来只有 0.3 左右，再压就糊进背景里了，深色底和浅色底上都会。
    final delta = hsl.lightness < 0.5 ? 0.14 : -(isDark ? 0.16 : 0.10);
    return hsl
        .withLightness((hsl.lightness + delta).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation * 0.82).clamp(0.0, 1.0))
        .toColor();
  }

  /// 徽章这类小色块的淡染底
  Color get accentTint => accent.withValues(alpha: isDark ? 0.20 : 0.16);

  /// 选中项（补全高亮、开关轨道）的淡染底
  Color get accentHighlight => accent.withValues(alpha: isDark ? 0.14 : 0.13);

  // ─────────────────────────── 文本色阶 ───────────────────────────

  /// 主文本 → 次要 → 辅助 → 弱提示
  Color get textPrimary =>
      isDark ? const Color(0xFFF2F5F8) : const Color(0xFF15181D);
  Color get textSecondary =>
      isDark ? const Color(0xFFC8D0D9) : const Color(0xFF474F5C);
  Color get textTertiary =>
      isDark ? const Color(0xFFA3ADB8) : const Color(0xFF6B7683);
  Color get textMuted =>
      isDark ? const Color(0xFF8B949F) : const Color(0xFF98A2AE);

  // ─────────────────────────── 背景 ───────────────────────────

  /// 没有背景图时铺的底色
  Color get background =>
      isDark ? const Color(0xFF0A0A0F) : const Color(0xFFF1F3F7);

  /// 压在背景图上的那层：深色下压黑，浅色下冲淡
  Color get overlay => isDark ? Colors.black : Colors.white;

  /// 空状态图标、分隔线这类"存在但别抢眼"的颜色
  Color get faintIcon => isDark ? Colors.white24 : Colors.black26;

  /// 「纯色」质量档下面板的底色。
  ///
  /// 不透明，但与背景差一档明度，好让面板的边界看得出来——
  /// 否则纯色档下所有面板会和背景连成一片。
  Color get solidSurface =>
      isDark ? const Color(0xFF171A21) : const Color(0xFFFFFFFF);

  // ─────────────────────────── 语义色 ───────────────────────────

  /// 成功就用主题色——用户改主题色时，历史里的对勾会一起变色
  Color get success => accent;

  Color get errorIcon =>
      isDark ? const Color(0xFFFF8A80) : const Color(0xFFD8434A);

  Color get errorText =>
      isDark ? const Color(0xFFFFAB91) : const Color(0xFFB33A3A);
}
