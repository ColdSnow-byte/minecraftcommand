import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
// `GlassQuality` 这个类型来自库本身，glass.dart 只做了档位枚举与映射
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'glass.dart';

// ─────────────────────────── 明暗模式 ───────────────────────────

/// 明暗模式的三种选择。带上 [label] / [icon] 是为了让设置页直接用枚举渲染，
/// 将来加一档（比如"跟随省电模式"）时不用同步改 UI。
enum AppBrightnessMode {
  system('跟随系统', Icons.brightness_auto_outlined),
  light('浅色', Icons.light_mode_outlined),
  dark('深色', Icons.dark_mode_outlined);

  const AppBrightnessMode(this.label, this.icon);

  final String label;
  final IconData icon;

  /// 在给定的系统亮度下，这一档实际是深色还是浅色
  bool resolve(bool systemIsDark) => switch (this) {
    AppBrightnessMode.system => systemIsDark,
    AppBrightnessMode.light => false,
    AppBrightnessMode.dark => true,
  };
}

// ─────────────────────────── 设置模型 ───────────────────────────

/// `copyWith` 用它区分"没传这个参数"和"显式传了 null"。
const Object _unset = Object();

/// 一份完整的用户设置。
///
/// 全部字段都有默认值，所以旧版本存下来的 JSON 缺字段时也能正常读出来
/// （[fromJson] 逐字段取默认）。
@immutable
class AppSettings {
  const AppSettings({
    this.brightnessMode = AppBrightnessMode.dark,
    this.accentId = 'emerald',
    this.glassQualityMode = GlassQualityMode.premium,
    this.orbitEnabled = false,
    this.persistHistory = true,
    this.backgroundImagePath,
    this.backgroundBlur = 0.32,
    this.backgroundDim = 0.55,
  });

  final AppBrightnessMode brightnessMode;

  /// 调色板里的主题色 id
  final String accentId;

  /// 玻璃质量档位。
  ///
  /// 默认给最高档——观感优先。顶不住或者想省电时可以在设置里往下调，
  /// 最低那档会退化成一层次半透明衬底（见 glass.dart）。
  final GlassQualityMode glassQualityMode;

  /// 是否在每个玻璃组件的外缘显示一颗绕行的拖尾光球。
  ///
  /// 默认关闭：它纯粹是装饰，而且每多一个组件就多一层动画——
  /// 在低端机上是能明显感觉到的开销。
  final bool orbitEnabled;

  /// 是否把历史记录留在磁盘上（关掉只影响下次启动，当前会话照常显示）
  final bool persistHistory;

  /// 自定义背景图的本地路径（已拷进应用私有目录）
  final String? backgroundImagePath;

  /// 背景图模糊强度，0（清晰）..1（很糊）
  final double backgroundBlur;

  /// 背景图压暗/冲淡强度，0（原图）..1（几乎盖住）
  final double backgroundDim;

  /// 模糊滑块 → 高斯 sigma。上限 36 是肉眼几乎只剩色块的程度。
  double get blurSigma => backgroundBlur * 36;

  /// 压暗滑块 → 叠色不透明度。上限留 0.92，最狠也还能透出一点纹理。
  double get overlayOpacity => backgroundDim * 0.92;

  AppSettings copyWith({
    AppBrightnessMode? brightnessMode,
    String? accentId,
    GlassQualityMode? glassQualityMode,
    bool? orbitEnabled,
    bool? persistHistory,
    Object? backgroundImagePath = _unset,
    double? backgroundBlur,
    double? backgroundDim,
  }) {
    return AppSettings(
      brightnessMode: brightnessMode ?? this.brightnessMode,
      accentId: accentId ?? this.accentId,
      glassQualityMode: glassQualityMode ?? this.glassQualityMode,
      orbitEnabled: orbitEnabled ?? this.orbitEnabled,
      persistHistory: persistHistory ?? this.persistHistory,
      backgroundImagePath: identical(backgroundImagePath, _unset)
          ? this.backgroundImagePath
          : backgroundImagePath as String?,
      backgroundBlur: backgroundBlur ?? this.backgroundBlur,
      backgroundDim: backgroundDim ?? this.backgroundDim,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'brightness': brightnessMode.name,
    'accent': accentId,
    'glass': glassQualityMode.name,
    'orbit': orbitEnabled,
    'persistHistory': persistHistory,
    'bg': backgroundImagePath,
    'blur': backgroundBlur,
    'dim': backgroundDim,
  };

  /// 宽容解析：任何一项坏了都只丢那一项，不至于把整份设置重置。
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const fallback = AppSettings();
    return AppSettings(
      brightnessMode: AppBrightnessMode.values.firstWhere(
        (m) => m.name == json['brightness'],
        orElse: () => fallback.brightnessMode,
      ),
      accentId: json['accent'] is String
          ? json['accent'] as String
          : fallback.accentId,
      glassQualityMode: GlassQualityMode.values.firstWhere(
        (m) => m.name == json['glass'],
        orElse: () => fallback.glassQualityMode,
      ),
      orbitEnabled: json['orbit'] is bool
          ? json['orbit'] as bool
          : fallback.orbitEnabled,
      persistHistory: json['persistHistory'] is bool
          ? json['persistHistory'] as bool
          : fallback.persistHistory,
      backgroundImagePath: json['bg'] is String
          ? json['bg'] as String
          : fallback.backgroundImagePath,
      // 注意别写成 `(json['blur'] as num?)`：类型不符时 as 会直接抛 TypeError，
      // 而不是得到 null，整份设置就白读了
      backgroundBlur: json['blur'] is num
          ? (json['blur'] as num).toDouble()
          : fallback.backgroundBlur,
      backgroundDim: json['dim'] is num
          ? (json['dim'] as num).toDouble()
          : fallback.backgroundDim,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.brightnessMode == brightnessMode &&
      other.accentId == accentId &&
      other.glassQualityMode == glassQualityMode &&
      other.orbitEnabled == orbitEnabled &&
      other.persistHistory == persistHistory &&
      other.backgroundImagePath == backgroundImagePath &&
      other.backgroundBlur == backgroundBlur &&
      other.backgroundDim == backgroundDim;

  @override
  int get hashCode => Object.hash(
    brightnessMode,
    accentId,
    glassQualityMode,
    orbitEnabled,
    persistHistory,
    backgroundImagePath,
    backgroundBlur,
    backgroundDim,
  );
}

// ─────────────────────────── 设置持久化 ───────────────────────────

/// 设置的读写。用单个 JSON 串存，加字段不需要动迁移代码。
class SettingsStore {
  static const _key = 'app_settings_v1';

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const AppSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const AppSettings();
      return AppSettings.fromJson(decoded);
    } catch (_) {
      // 设置读坏不该让应用起不来——任何异常都退回默认值
      return const AppSettings();
    }
  }

  static Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }
}

// ─────────────────────────── 背景图文件管理 ───────────────────────────

/// 负责挑图、把图拷进应用私有目录、以及清理换下来的旧图。
///
/// 之所以要拷贝而不是直接存相册路径：相册里的 URI 会被系统回收，
/// 用户删掉原图后背景就白了。
class BackgroundImageStore {
  static const _baseName = 'custom_background';

  /// 弹系统选择器，返回新背景图的本地路径；用户取消则返回 null。
  static Future<String?> pick() async {
    final picked = await FilePicker.pickFile(type: FileType.image);
    final source = picked?.path;
    if (source == null) return null;

    final dir = await getApplicationSupportDirectory();
    await _deleteAllSaved(dir);

    final target = File('${dir.path}/$_baseName${_extensionOf(source)}');
    await File(source).copy(target.path);
    return target.path;
  }

  /// 删除指定的背景图文件（用户点"移除背景"时）。
  static Future<void> remove(String? path) async {
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// 启动时校验：文件被外部删掉时返回 false，让 UI 回落到渐变背景。
  static Future<bool> exists(String? path) async =>
      path != null && await File(path).exists();

  /// 扩展名可能缺失（Android 的 content URI 拷出来往往没有），兜底给 `.img`。
  static String _extensionOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    final dot = path.lastIndexOf('.');
    if (dot <= slash || dot == path.length - 1) return '.img';
    final ext = path.substring(dot);
    return ext.length > 6 ? '.img' : ext;
  }

  static Future<void> _deleteAllSaved(Directory dir) async {
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (name.startsWith('$_baseName.')) await entry.delete();
    }
  }
}

// ─────────────────────────── 全局控制器 ───────────────────────────

/// 持有当前设置，并把每次修改落盘。
///
/// 通过 [AppSettingsScope]（一个 `InheritedNotifier`）下发，所以任何
/// `context.palette` 都会在换主题时自动重建。
class AppSettingsController extends ChangeNotifier {
  AppSettingsController(this._settings);

  AppSettings _settings;

  AppSettings get settings => _settings;

  /// 结合"设置里的明暗档位"和"系统当前亮度"，算出真正生效的配色。
  AppPalette paletteFor(bool systemIsDark) => AppPalette(
    accent: accentById(_settings.accentId).color,
    isDark: _settings.brightnessMode.resolve(systemIsDark),
  );

  /// 统一的写入口：去重 → 通知 → 落盘。
  ///
  /// 滑块拖动会高频调用，所以先用 [AppSettings] 的相等判断挡掉无变化的帧，
  /// 避免每帧都写一次磁盘。
  void update(AppSettings next) {
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    unawaited(SettingsStore.save(next));
  }

  void setBrightnessMode(AppBrightnessMode mode) =>
      update(_settings.copyWith(brightnessMode: mode));

  void setAccent(String accentId) =>
      update(_settings.copyWith(accentId: accentId));

  void setGlassQualityMode(GlassQualityMode mode) =>
      update(_settings.copyWith(glassQualityMode: mode));

  void setOrbitEnabled(bool value) =>
      update(_settings.copyWith(orbitEnabled: value));

  /// 只负责改设置。磁盘上的存档由 [HistoryController] 清理，
  /// 两边通过设置页的开关一起驱动。
  void setPersistHistory(bool value) =>
      update(_settings.copyWith(persistHistory: value));

  void setBackgroundImage(String? path) =>
      update(_settings.copyWith(backgroundImagePath: path));

  void setBackgroundBlur(double value) =>
      update(_settings.copyWith(backgroundBlur: value));

  void setBackgroundDim(double value) =>
      update(_settings.copyWith(backgroundDim: value));
}

/// 把 [AppSettingsController] 注入组件树。
class AppSettingsScope extends InheritedNotifier<AppSettingsController> {
  const AppSettingsScope({
    super.key,
    required AppSettingsController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppSettingsController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppSettingsScope>();
    assert(scope != null, '组件树上没有 AppSettingsScope，检查根组件是否包了它');
    return scope!.notifier!;
  }
}

/// 取用设置的语法糖。
extension AppSettingsContext on BuildContext {
  AppSettingsController get settingsController => AppSettingsScope.of(this);

  AppSettings get appSettings => AppSettingsScope.of(this).settings;

  /// 当前配色。读 [MediaQuery.platformBrightnessOf] 建立依赖，
  /// 所以系统在浅色/深色间切换时（"跟随系统"档位下）会重建。
  AppPalette get palette =>
      AppSettingsScope.of(this)
          .paletteFor(MediaQuery.platformBrightnessOf(this) == Brightness.dark);

  /// 当前玻璃质量档位——**完整档**。
  ///
  /// 只给显式设了 `useOwnLayer: true` 的组件用（底部输入面板、右上角切换器）：
  /// 它们能自己提供几何图层，扛得住 premium。
  ///
  /// 在设置里改一档会立刻生效，不需要重启——`AppSettingsScope` 是
  /// [InheritedNotifier]，设置一变依赖它的组件就重建，
  /// `GlassContainer` 会用新档位重新布局与绘制。
  GlassQuality get glassQuality => qualityFor(appSettings.glassQualityMode);

  /// 当前档位是否还要用玻璃组件。
  ///
  /// 「纯色」档为 false——那时面板会换成普通的圆角色块。
  bool get glassEnabled => usesGlass(appSettings.glassQualityMode);
}
