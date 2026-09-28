import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_palette.dart';
import 'app_settings.dart';
import 'app_shell.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 先把读设置的 Future 起起来，再等两件初始化的事——三者并行，少等一轮
  final settingsFuture = SettingsStore.load();
  await RustLib.init();
  await LiquidGlassWidgets.initialize();

  runApp(MinecraftCommandApp(initialSettings: await settingsFuture));
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
  final isDark = Theme.maybeBrightnessOf(context) != Brightness.light;
  return CupertinoTheme(
    // 让 CupertinoColors.label 等动态颜色按当前明暗解析（Toast 文字色依赖它）
    data: CupertinoThemeData(
      brightness: isDark ? Brightness.dark : Brightness.light,
    ),
    child: DefaultTextStyle(
      style: TextStyle(
        color: isDark ? Colors.white : const Color(0xFF15181D),
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

class MinecraftCommandApp extends StatefulWidget {
  const MinecraftCommandApp({super.key, required this.initialSettings});

  /// 启动时从磁盘读到的设置（由 [main] 预先加载，避免首帧闪一下默认配色）
  final AppSettings initialSettings;

  @override
  State<MinecraftCommandApp> createState() => _MinecraftCommandAppState();
}

class _MinecraftCommandAppState extends State<MinecraftCommandApp>
    with WidgetsBindingObserver {
  late final AppSettingsController _settings = AppSettingsController(
    widget.initialSettings,
  );

  @override
  void initState() {
    super.initState();
    // 顶层拿不到 MediaQuery，系统明暗切换只能靠这个回调感知
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settings.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final systemIsDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;

    // 设置一变就重建 MaterialApp，让 ThemeData 里面的明暗与种子色跟上
    return AnimatedBuilder(
      animation: _settings,
      builder: (context, _) {
        final settings = _settings.settings;
        final isDark = settings.brightnessMode.resolve(systemIsDark);
        final accent = accentById(settings.accentId).color;

        return AppSettingsScope(
          controller: _settings,
          child: LiquidGlassWidgets.wrap(
            // 具体档位由设置里的「质量等级」决定（见 glass.dart），
            // 各组件通过 `context.glassQuality` 读取，改一档全界面立即生效。
            // 这里保留自适应开关，库内部还有一层兜底判断。
            adaptiveQuality: true,
            // wrap 挂在 MaterialApp 之上，`Theme.maybeBrightnessOf` 在这里拿不到，
            // 所以直接把算好的明暗喂给它，玻璃才能跟着切深浅。
            brightnessResolver: (_) =>
                isDark ? Brightness.dark : Brightness.light,
            child: MaterialApp(
              title: 'Minecraft 指令台',
              debugShowCheckedModeBanner: false,
              // 这里**不能**包 AdaptiveLiquidGlassLayer。
              //
              // 它不是一个透明的"共享层"，而是会真的绘制一层玻璃
              // （源码注释：Painting a BackdropFilter + tinted Container here）。
              // 包住整个 app 等于盖了一层全屏毛玻璃，界面会整体糊掉。
              //
              // 需要折射的组件改为各自 useOwnLayer: true，见 glass.dart。
              builder: appShellBuilder,
              theme: _themeFor(accent: accent, isDark: isDark),
              home: const AppShell(),
            ),
          ),
        );
      },
    );
  }

  /// 主题色做种子，Material 组件（对话框、SnackBar、开关）也跟着一起变。
  ThemeData _themeFor({required Color accent, required bool isDark}) {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
      ),
      // 背景由 AppBackground 画，Scaffold 保持透明才能透出自定义图片
      scaffoldBackgroundColor: Colors.transparent,
    );
  }
}
