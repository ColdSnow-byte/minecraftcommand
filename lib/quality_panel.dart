import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_settings.dart';
import 'orbit.dart';

/// 一块按当前质量档渲染的面板。
///
/// - 玻璃档（极致 / 标准 / 半透明）→ 交给 [GlassContainer]；
/// - 纯色档 → 一个普通的圆角色块，零特效、零模糊。
///
/// 顺带把两条容易写错的规则收在这里，免得每处调用各写一遍：
/// 用 premium 时必须 `useOwnLayer: true`；滚动列表里的卡片必须封顶在
/// [GlassQuality.standard]。
class QualityPanel extends StatelessWidget {
  const QualityPanel({
    super.key,
    required this.child,
    this.radius = 16,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.showOrbit = true,
    this.capQuality,
  });

  final Widget child;

  /// 圆角半径。玻璃模式下作为超椭圆的圆角，纯色模式下作为普通圆角。
  ///
  /// 必须与 `OrbitGlow` 用的值一致——光球要沿这条边跑。
  final double radius;

  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  /// 是否允许在这块面板上叠加环绕光球（默认允许，实际是否显示由设置决定）
  final bool showOrbit;

  /// 强制指定玻璃档位。
  ///
  /// **滚动列表里的卡片必须传 [GlassQuality.standard]。** premium 在滚动
  /// 容器里会出故障：面板背景发黑、内容跑到面板外、约 0.2 秒后才跳回来——
  /// 这是官方文档承认的限制（"may not render correctly in scrollable
  /// contexts"），因为列表项会被回收重建，捕获到的几何信息对不上。
  final GlassQuality? capQuality;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    Widget surface = context.glassEnabled
        ? GlassContainer(
            quality: capQuality ?? context.glassQuality,
            // premium 需要一块自己的几何图层，漏了会直接断言失败
            useOwnLayer: true,
            padding: padding,
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            child: child,
          )
        : Container(
            padding: padding,
            decoration: BoxDecoration(
              color: palette.solidSurface,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: child,
          );

    // 光球包在玻璃之上、外边距之内：
    // 放在外边距外面的话，光球会绕着一块比面板大的矩形跑。
    if (showOrbit) {
      surface = OrbitGlow(radius: radius, child: surface);
    }

    if (margin != null) {
      surface = Padding(padding: margin!, child: surface);
    }

    return surface;
  }
}
