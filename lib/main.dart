import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'command_console.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await LiquidGlassWidgets.initialize();
  runApp(const MinecraftCommandApp());
}

/// MaterialApp 的 builder：为 Navigator **之上**的层级补充必要的上下文。
///
/// 原因：MaterialApp 会把 `textStyle: _errorTextStyle`（红色 48px 等宽 +
/// **黄色双下划线**，用于提示“文字未放在 Material 内”）传给 WidgetsApp 并
/// 包裹整个应用；而 `Material`/`Scaffold` 会提供自己的 DefaultTextStyle，
/// 所以页面内文字正常。但 Overlay 条目（如 `GlassToast.show` 插入的 Toast）
/// 位于 Navigator 的 Overlay 中、**不在任何 Material 内部**，于是继承了这份
/// 兜底样式。Toast 的 Text 只覆盖了 color/fontSize，下划线便被合并保留下来。
///
/// MaterialApp.builder 插入在 Navigator 之上，因此这里的 DefaultTextStyle
/// 能覆盖那份兜底样式，且会被各路由内的 Material 再次覆盖，不影响页面内文字。
Widget appShellBuilder(BuildContext context, Widget? child) {
  return CupertinoTheme(
    // 让 CupertinoColors.label 等动态颜色按深色解析（Toast 文字色依赖它）
    data: const CupertinoThemeData(brightness: Brightness.dark),
    child: DefaultTextStyle(
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.2,
        decoration: TextDecoration.none,
        decorationColor: Colors.transparent,
      ),
      child: child ?? const SizedBox.shrink(),
    ),
  );
}

class MinecraftCommandApp extends StatelessWidget {
  const MinecraftCommandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassWidgets.wrap(
      // 在支持 Impeller 的平台（iOS/Android/macOS）上使用 GlassQuality.premium；
      // 在 Skia 平台（Windows/Linux/Web）上自动降级为标准质量——否则 premium
      // 着色器管线不生效，玻璃面板会静默渲染成空白。
      adaptiveQuality: true,
      // 让玻璃的明暗模式跟随 MaterialApp 的 ThemeMode（本项目为深色）
      brightnessResolver: Theme.maybeBrightnessOf,
      child: MaterialApp(
        title: 'Minecraft 指令台',
        debugShowCheckedModeBanner: false,
        builder: appShellBuilder,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0A0A0F),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF10B981),
            brightness: Brightness.dark,
          ),
        ),
        home: const CommandConsolePage(),
      ),
    );
  }
}
