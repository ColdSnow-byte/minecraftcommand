import 'dart:ui' as ui;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 玻璃质量档位，对应设置页里的"质量等级"。
///
/// 分三档，取舍是「观感 ↔ 流畅度」：
///
/// - [premium]：纹理捕获 + 自定义着色器，有边缘高光与**色散**
///   （chromatic aberration）。最像 iOS 26，但每帧要抓一次屏幕纹理，
///   高分辨率设备上开销明显。
/// - [standard]：轻量片元着色器，只做模糊与染色，没有折射。库推荐的默认档，
///   比 `BackdropFilter` 快 5-10 倍，滚动时也稳。
/// - [minimal]：完全绕开着色器，退化成 `ClipPath + BackdropFilter + 染色`
///   的一层半透明衬底。观感最朴素，但也最省电。
enum GlassQualityMode {
  premium('高', '边缘折射与色散，模糊与染色'),
  standard('中', '有模糊与染色，没有折射色散'),
  minimal('低', '仅半透明背景'),
  solid('极低', '纯色块背景');
  // premium('高', ''),
  // standard('中', ''),
  // minimal('低', ''),
  // solid('极低', '');

  const GlassQualityMode(this.label, this.description);

  final String label;
  final String description;
}

/// 这一档是否还要用玻璃组件。
///
/// [GlassQualityMode.solid] 是"完全不碰玻璃"，由调用方（`QualityPanel`）
/// 换成普通的圆角色块。注意不能简单地把这一档映射成
/// [GlassQuality.minimal]——库里最低的那档仍然会经过一层 `BackdropFilter`，
/// 也就是**还带着模糊**，那并不是用户要的"纯色块"。
bool usesGlass(GlassQualityMode mode) => mode != GlassQualityMode.solid;

/// 把用户选的档位翻译成库里的枚举——**完整档**，只给显式开了图层的组件用。
///
/// 用它的组件必须同时设 `useOwnLayer: true`，否则会抛
/// `LiquidGlassBlendGroup could not find an InheritedGeometryRenderLink`。
/// 目前只有底部输入面板和右上角切换器满足这个条件。
///
/// premium 的着色器管线依赖 Impeller：Skia 平台（Windows / Linux / Web）上
/// 不生效，玻璃会**静默渲染成空白**。所以那里自动退回 [GlassQuality.standard]。
/// 用户界面上仍然显示"极致"，只是实际跑的是能用的那一档——
/// 这比让他选了一个会让界面变空白的选项要好。
GlassQuality qualityFor(GlassQualityMode mode) {
  return switch (mode) {
    // 纯色档正常不会走到这里（调用方会换成普通色块），兜底给最省电的一档
    GlassQualityMode.solid => GlassQuality.minimal,
    GlassQualityMode.minimal => GlassQuality.minimal,
    GlassQualityMode.standard => GlassQuality.standard,
    GlassQualityMode.premium =>
      ui.ImageFilter.isShaderFilterSupported
          ? GlassQuality.premium
          : GlassQuality.standard,
  };
}

/// 弹窗（库里的 `GlassDialog`）实际用的玻璃档位。
///
/// premium 要求组件自己开一块捕获图层（`LiquidGlass.withOwnLayer`，内部靠
/// `toImageSync` 抓一次屏幕）。弹窗是**新挂载**的组件，这块层的几何信息在第一帧
/// 还没建立起来，玻璃于是只画出一半、约 0.2 秒后才跳成完整——点左上角图标时
/// 看到的"先冒出半个框、再变成整块"就是它。根因跟滚动列表里的卡片一样（见
/// quality_panel.dart 里 `capQuality` 的说明）。
///
/// 所以这里把弹窗的玻璃封顶在 [GlassQuality.standard]：标准档走的是实时着色器
/// （`LightweightLiquidGlass`，不抓屏），第一帧就是对的。代价是弹窗少了 premium
/// 的折射与色散——比起每次打开都要闪一下，这个交换划算。
GlassQuality dialogQualityFor(GlassQualityMode mode) {
  final quality = qualityFor(mode);
  return quality == GlassQuality.premium ? GlassQuality.standard : quality;
}

// 每个用 premium 的玻璃组件都要设 `useOwnLayer: true`。
//
// 这个库没有"一处开层、全树共享"的便捷入口：`GlassScaffold` 只包了
// `GlassIsolationScope`，并不建立 `LiquidGlassLayer`；而
// `AdaptiveLiquidGlassLayer` 不是透明的共享层——它自己会画一层玻璃，
// 包住整个 app 会把界面整体糊掉。
//
// 所以走逐组件开层：组件各开一块匹配自身形状的捕获图层。
// 库自带的层只有 `GlassDialog` / `GlassToast` / `GlassTabBar.bottom` 等
// 少数几个，它们不需要手动设这个参数。
//
// 代价是每帧多次纹理捕获，高分辨率设备上会掉帧——这正是设置页里
// 「质量等级」的用途：降到「标准」即可全部关掉折射。如果某个组件
// 漏设了 `useOwnLayer`，premium 会抛
// `LiquidGlassBlendGroup could not find an InheritedGeometryRenderLink`。
