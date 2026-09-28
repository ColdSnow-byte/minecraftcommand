import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_settings.dart';

/// 系统是否要求"减弱动态效果"。
///
/// 与 app_background.dart 里那份是同一个判断，这里单独放一份是为了
/// 不把背景绘制模块拖进普通组件——它有 `dart:io` 依赖。
bool _reduceMotion() => WidgetsBinding
    .instance
    .platformDispatcher
    .accessibilityFeatures
    .disableAnimations;

/// 在子组件的外边缘绕行的一颗呼吸光球。
///
/// 观感参照老手机的呼吸灯：光点很小、光晕很散、亮度缓慢起伏，
/// 而不是一颗恒亮的小球在跑。由设置里的「光球环绕」开关控制（默认关闭）。
///
/// 关掉时**直接返回 child**，不建动画控制器、不装绘制层，等于零开销——
/// 所以可以放心地在每个玻璃组件外面都包一层。
///
/// [radius] 应当与子组件的圆角保持一致，否则光球会跑进/跑出边角。
class OrbitGlow extends StatelessWidget {
  const OrbitGlow({
    super.key,
    required this.child,
    this.radius = 16,
    this.enabled,
  });

  final Widget child;

  /// 子组件的圆角半径
  final double radius;

  /// 覆盖设置里的开关（主要用于预览或测试）；为 null 时读设置
  final bool? enabled;

  @override
  Widget build(BuildContext context) {
    final on = enabled ?? context.appSettings.orbitEnabled;
    if (!on || _reduceMotion()) return child;

    return _OrbitAnimation(
      accent: context.palette.accent,
      radius: radius,
      child: child,
    );
  }
}

class _OrbitAnimation extends StatefulWidget {
  const _OrbitAnimation({
    required this.child,
    required this.accent,
    required this.radius,
  });

  final Widget child;
  final Color accent;
  final double radius;

  @override
  State<_OrbitAnimation> createState() => _OrbitAnimationState();
}

class _OrbitAnimationState extends State<_OrbitAnimation>
    with SingleTickerProviderStateMixin {
  /// 绕行一圈的时长。
  ///
  /// 14 秒——比"看起来像在动"所需的下限慢得多。老手机的呼吸灯本来就是
  /// 一种几乎察觉不到变化的暗示，转快了就变成跑马灯，味道全没了。
  static const _period = Duration(seconds: 14);

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
    return RepaintBoundary(
      child: CustomPaint(
        // 画在 child 之上：光晕压在玻璃边缘上，看起来像贴着边渗出来
        foregroundPainter: _OrbitPainter(
          animation: _controller,
          accent: widget.accent,
          radius: widget.radius,
        ),
        willChange: true,
        child: widget.child,
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.animation,
    required this.accent,
    required this.radius,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color accent;
  final double radius;

  /// 拖尾上的光点数（含头部）
  static const _trailCount = 16;

  /// 相邻光点的间距，占整个周长的比例。
  /// 16 × 0.009 ≈ 14%，也就是拖尾大约占边缘总长的七分之一。
  static const _trailGap = 0.009;

  /// 头部光点的半径（像素）。
  ///
  /// 刻意取小——呼吸灯的重点是那圈散开的光晕，不是中间那个亮点。
  static const _headRadius = 1.5;

  /// 光晕相对亮点的倍率。放得很大才够柔。
  static const _haloScale = 3.4;

  /// 一圈里亮度起伏几次。14 ÷ 3 ≈ 4.7 秒一个明暗循环，
  /// 接近老手机那颗绿灯的节奏。
  static const _breathCount = 3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final r = math.min(radius, math.min(size.width, size.height) / 2);
    if (r <= 0) return;

    // 用 PathMetric 沿周长取点：圆角处是按弧长参数化的，
    // 所以光球经过转角时速度连续，不会"卡"一下。
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r)),
      );
    final metric = path.computeMetrics().firstOrNull;
    final total = metric?.length ?? 0;
    if (metric == null || total <= 0) return;

    final t = animation.value;

    // 呼吸：整条光带的亮度随时间缓慢起伏，这是"呼吸灯"和"跑马灯"的分界。
    // 频率取 _breathCount 的整数倍，t 绕回 0 时刚好接上，不会跳变。
    final breath =
        0.28 + 0.72 * (0.5 + 0.5 * math.sin(t * _breathCount * 2 * math.pi));

    // 从尾到头绘制，这样头部会盖在拖尾之上
    for (var i = _trailCount - 1; i >= 0; i--) {
      // 取模是为了让拖尾跨过起点时从另一端接上，而不是凭空消失
      final progress = (t - i * _trailGap) % 1.0;
      final tangent = metric.getTangentForOffset(progress * total);
      if (tangent == null) continue;

      // 头部最亮最大，往后按平方衰减。峰值不透明度压到 0.7 且再乘呼吸值，
      // 让光始终是"透"出来的而不是糊上去的。
      final fade = 1 - i / _trailCount;
      final intensity = fade * fade * breath;
      final dotRadius = _headRadius * (0.35 + 0.65 * fade);
      final core = accent.withValues(alpha: 0.70 * intensity);
      final halo = dotRadius * _haloScale;

      canvas.drawCircle(
        tangent.position,
        halo,
        Paint()
          ..shader =
              RadialGradient(
                // 中间插一个 stop，把亮点到全透明的过渡拉长——
                // 两段式渐变会在边缘留下一个能看见的硬圈
                colors: <Color>[
                  core,
                  core.withValues(alpha: core.a * 0.35),
                  core.withValues(alpha: 0),
                ],
                stops: const <double>[0.0, 0.40, 1.0],
              ).createShader(
                Rect.fromCircle(center: tangent.position, radius: halo),
              ),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.accent != accent ||
      oldDelegate.radius != radius;
}
