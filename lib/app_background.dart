import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_settings.dart';

/// 全屏背景，从下往上三层：
///
/// 1. 纯色底（[AppPalette.background]）；
/// 2. 用户自定义图片——按设置做高斯模糊，再叠一层明暗色压暗；
/// 3. 动态流光——若干缓慢漂移的光斑，外加一道周期性掠过的斜向光带。
///
/// 整层套了 [RepaintBoundary] 与 `IgnorePointer`：既不抢触摸事件，
/// 每帧重绘也不会带上层的列表和玻璃面板。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final settings = context.appSettings;
    final imagePath = settings.backgroundImagePath;

    return RepaintBoundary(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: palette.background),
            if (imagePath != null)
              _BackgroundPhoto(
                path: imagePath,
                blurSigma: settings.blurSigma,
                overlay: palette.overlay,
                overlayOpacity: settings.overlayOpacity,
              ),
            _GlowLayer(accent: palette.accent, isDark: palette.isDark),
          ],
        ),
      ),
    );
  }
}

/// 自定义背景图：模糊 + 压暗。
class _BackgroundPhoto extends StatelessWidget {
  const _BackgroundPhoto({
    required this.path,
    required this.blurSigma,
    required this.overlay,
    required this.overlayOpacity,
  });

  final String path;
  final double blurSigma;
  final Color overlay;
  final double overlayOpacity;

  @override
  Widget build(BuildContext context) {
    Widget image = Image.file(
      File(path),
      fit: BoxFit.cover,
      // 背景反正要模糊，解码时就把宽度压到 720：既省掉一张 4K 图的内存，
      // 拖动模糊滑块时也不会因为每帧重算高斯而掉帧
      cacheWidth: 720,
      gaplessPlayback: true,
      // 文件被外部删掉/损坏时静默退回纯色底，不要抛红屏
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    if (blurSigma > 0.1) {
      // 模糊会让图片边缘透出透明像素，所以放大一点点把四边顶出画布
      final bleed = 1 + blurSigma * 0.008;
      image = Transform.scale(
        scale: bleed,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: blurSigma,
            sigmaY: blurSigma,
          ),
          child: image,
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        image,
        if (overlayOpacity > 0.001)
          ColoredBox(color: overlay.withValues(alpha: overlayOpacity)),
      ],
    );
  }
}

// ─────────────────────────── 动态流光 ───────────────────────────

/// 系统是否要求"减弱动态效果"。
///
/// 用 `platformDispatcher` 而不是 `MediaQuery`：这样在 `initState` 里就能取到，
/// 组件可以保持不依赖 `InheritedWidget`。
bool _reduceMotion() => WidgetsBinding
    .instance
    .platformDispatcher
    .accessibilityFeatures
    .disableAnimations;

/// 流光层：光斑漂移 + 扫光掠过。
///
/// 性能取舍：
/// - 动画只发生在**绘制阶段**（[CustomPainter] 通过 `super(repaint: ...)` 直接
///   监听 [AnimationController]），不触发 build / layout；
/// - 光斑数量（4 个）和扫光都是固定的，每帧只创建 Shader 不重建渐变对象；
/// - 系统开启"减弱动态效果"时退化为静态光斑并停表。
class _GlowLayer extends StatefulWidget {
  const _GlowLayer({required this.accent, required this.isDark});

  final Color accent;
  final bool isDark;

  @override
  State<_GlowLayer> createState() => _GlowLayerState();
}

class _GlowLayerState extends State<_GlowLayer>
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
    return RepaintBoundary(
      child: CustomPaint(
        painter: _GlowPainter(
          animation: _reduceMotion()
              ? const AlwaysStoppedAnimation<double>(0)
              : _controller,
          accent: widget.accent,
          isDark: widget.isDark,
        ),
        willChange: true,
      ),
    );
  }
}

/// 一个光斑的静态描述。
///
/// 色相写成**相对主题色的偏移**：换主题色时四个光斑整体跟着旋转，
/// 彼此的色彩关系保持不变，画面不会因为只有一处变色而显得割裂。
class _BlobSpec {
  const _BlobSpec({
    required this.hueShift,
    required this.saturation,
    required this.lightness,
    required this.alpha,
    required this.centerX,
    required this.centerY,
    required this.radius,
    required this.driftX,
    required this.driftY,
    required this.phase,
  });

  /// 相对主题色相的偏移角度
  final double hueShift;
  final double saturation;
  final double lightness;

  /// 深色模式下的峰值不透明度（浅色模式会再压低）
  final double alpha;

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
  _GlowPainter({
    required this.animation,
    required this.accent,
    required this.isDark,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color accent;
  final bool isDark;

  /// 四个光斑：主色相、邻近色、另一个邻近色，以及一个远端的互补色。
  /// 互补色那一个负责撑开层次，避免同色系堆在一起糊成一片。
  static const List<_BlobSpec> _specs = <_BlobSpec>[
    _BlobSpec(
      hueShift: 0,
      saturation: 0.72,
      lightness: 0.48,
      alpha: 0.30,
      centerX: 0.88,
      centerY: -0.06,
      radius: 0.74,
      driftX: 0.06,
      driftY: 0.05,
      phase: 0.00,
    ),
    _BlobSpec(
      hueShift: 32,
      saturation: 0.70,
      lightness: 0.56,
      alpha: 0.22,
      centerX: -0.14,
      centerY: 0.94,
      radius: 0.86,
      driftX: 0.08,
      driftY: 0.06,
      phase: 0.37,
    ),
    _BlobSpec(
      hueShift: -40,
      saturation: 0.66,
      lightness: 0.60,
      alpha: 0.20,
      centerX: 1.04,
      centerY: 0.54,
      radius: 0.66,
      driftX: 0.05,
      driftY: 0.09,
      phase: 0.68,
    ),
    _BlobSpec(
      hueShift: 160,
      saturation: 0.62,
      lightness: 0.58,
      alpha: 0.16,
      centerX: 0.32,
      centerY: 1.10,
      radius: 0.58,
      driftX: 0.10,
      driftY: 0.04,
      phase: 0.19,
    ),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final t = animation.value;
    final shortest = size.shortestSide;
    final baseHue = HSLColor.fromColor(accent).hue;
    // 浅色底上光斑要收着点，否则会脏
    final alphaScale = isDark ? 1.0 : 0.55;

    canvas.clipRect(Offset.zero & size);

    for (final spec in _specs) {
      // 两个不同频率的正弦叠加，避免所有光斑整齐划一地摆动
      final dx =
          math.sin((t + spec.phase) * 2 * math.pi) * spec.driftX * size.width;
      final dy =
          math.cos((t * 0.74 + spec.phase) * 2 * math.pi) *
          spec.driftY *
          size.height;
      final breath =
          0.90 + 0.10 * math.sin((t * 1.37 + spec.phase) * 2 * math.pi);

      final center = Offset(
        spec.centerX * size.width + dx,
        spec.centerY * size.height + dy,
      );
      final radius = spec.radius * shortest * breath;
      final peak = HSLColor.fromAHSL(
        spec.alpha * alphaScale,
        (baseHue + spec.hueShift) % 360,
        spec.saturation,
        spec.lightness,
      ).toColor();

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[peak, peak.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    _paintSweep(canvas, size, t, baseHue, alphaScale);
  }

  /// 一道低透明度的斜向光带：每个循环扫两次，其余时间留白形成间歇节奏。
  void _paintSweep(
    Canvas canvas,
    Size size,
    double t,
    double baseHue,
    double alphaScale,
  ) {
    const travelPortion = 0.55; // 单次扫光占循环的比例
    final progress = (t * 2) % 1.0;
    if (progress > travelPortion) return;
    final travel = progress / travelPortion; // 0..1

    final bandWidth = size.width * 0.34;
    final diagonal = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    final x = -bandWidth + travel * (size.width + bandWidth * 2);

    // 扫光比主题色更亮一档，看起来像高光而不是一块色斑
    final bright = HSLColor.fromAHSL(
      0.13 * alphaScale,
      baseHue,
      0.55,
      0.72,
    ).toColor();
    final faint = bright.withValues(alpha: 0.07 * alphaScale);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-0.42); // 斜向 ≈ -24°
    final rect = Rect.fromCenter(
      center: Offset(x - size.width / 2, 0),
      width: bandWidth,
      height: diagonal * 1.2,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            faint.withValues(alpha: 0),
            faint,
            bright,
            faint,
            faint.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    canvas.restore();
  }

  /// 重绘由 `repaint: animation` 驱动；这里只处理主题色/明暗切换时的重绘。
  @override
  bool shouldRepaint(_GlowPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.accent != accent ||
      oldDelegate.isDark != isDark;
}
