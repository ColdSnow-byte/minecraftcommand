import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:minecraftcommand/app_palette.dart';
import 'package:minecraftcommand/app_settings.dart';
import 'package:minecraftcommand/glass.dart';
import 'package:minecraftcommand/history.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 让 `HistoryController.add` 内部那个 fire-and-forget 的落盘跑完。
Future<void> _flushDisk() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings', () {
    test('JSON 往返后完全一致', () {
      const original = AppSettings(
        brightnessMode: AppBrightnessMode.light,
        accentId: 'violet',
        persistHistory: false,
        backgroundImagePath: '/tmp/bg.png',
        backgroundBlur: 0.75,
        backgroundDim: 0.2,
        suggestionPanelHeight: 160,
        inputMaxLines: 8,
      );

      expect(AppSettings.fromJson(original.toJson()), original);
    });

    test('旧版本缺字段时回落到默认值', () {
      expect(AppSettings.fromJson(<String, dynamic>{}), const AppSettings());
    });

    test('单项类型损坏时只丢那一项', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'brightness': 'dark',
        'accent': 42, // 应为 String
        'persistHistory': false,
        'blur': 'x', // 应为 num
      });

      expect(restored.brightnessMode, AppBrightnessMode.dark);
      expect(restored.accentId, 'emerald');
      expect(restored.persistHistory, isFalse);
      expect(restored.backgroundBlur, const AppSettings().backgroundBlur);
    });

    test('copyWith 能显式清空背景图，也能不传就保留', () {
      const withBackground = AppSettings(backgroundImagePath: '/a.png');

      expect(
        withBackground.copyWith(backgroundImagePath: null).backgroundImagePath,
        isNull,
      );
      expect(
        withBackground.copyWith(backgroundDim: 0.1).backgroundImagePath,
        '/a.png',
      );
    });

    test('明暗档位按系统亮度解析', () {
      expect(AppBrightnessMode.system.resolve(true), isTrue);
      expect(AppBrightnessMode.system.resolve(false), isFalse);
      expect(AppBrightnessMode.light.resolve(true), isFalse);
      expect(AppBrightnessMode.dark.resolve(false), isTrue);
    });

    test('光球环绕默认关闭，且能序列化往返', () {
      expect(const AppSettings().orbitEnabled, isFalse);
      expect(
        AppSettings.fromJson(const AppSettings(orbitEnabled: true).toJson())
            .orbitEnabled,
        isTrue,
      );
    });

    test('旧存档没有光球字段时保持关闭', () {
      // 缺字段要落到"关闭"，而不是因为 bool 默认值巧合而变开启
      expect(AppSettings.fromJson(<String, dynamic>{}).orbitEnabled, isFalse);
      expect(
        AppSettings.fromJson(<String, dynamic>{'orbit': '不是布尔值'}).orbitEnabled,
        isFalse,
      );
    });

    test('滑块取值映射到合理的 sigma / 不透明度', () {
      const max = AppSettings(backgroundBlur: 1, backgroundDim: 1);
      expect(max.blurSigma, 36);
      expect(max.overlayOpacity, closeTo(0.92, 0.0001));

      const min = AppSettings(backgroundBlur: 0, backgroundDim: 0);
      expect(min.blurSigma, 0);
      expect(min.overlayOpacity, 0);
    });
  });

  group('控制台尺寸', () {
    test('默认值落在可选范围内，且正好是某一档', () {
      const settings = AppSettings();

      expect(
        settings.suggestionPanelHeight,
        inInclusiveRange(kSuggestionPanelHeightMin, kSuggestionPanelHeightMax),
      );
      // 落在两档之间的话，滑块会停在档位缝隙里，读数与档位对不上
      expect(
        (settings.suggestionPanelHeight - kSuggestionPanelHeightMin) %
            kSuggestionPanelHeightStep,
        0,
      );
      expect(
        settings.inputMaxLines,
        inInclusiveRange(kInputMaxLinesMin, kInputMaxLinesMax),
      );
    });

    test('能序列化往返', () {
      const original = AppSettings(
        suggestionPanelHeight: 160,
        inputMaxLines: 9,
      );
      final restored = AppSettings.fromJson(original.toJson());

      expect(restored.suggestionPanelHeight, 160);
      expect(restored.inputMaxLines, 9);
    });

    test('旧存档没有这两个字段时回落到默认值', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'accent': 'violet',
      });

      expect(
        restored.suggestionPanelHeight,
        AppSettings().suggestionPanelHeight,
      );
      expect(restored.inputMaxLines, AppSettings().inputMaxLines);
    });

    test('越界的值被夹回可选范围', () {
      // 存档被手改过：值离谱也不能把底部面板撑爆、或让输入框消失
      final restored = AppSettings.fromJson(<String, dynamic>{
        'suggestH': 99999,
        'inputLines': -3,
      });

      expect(restored.suggestionPanelHeight, kSuggestionPanelHeightMax);
      expect(restored.inputMaxLines, kInputMaxLinesMin);
    });

    test('类型损坏时只丢那一项', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'suggestH': '好高',
        'inputLines': <int>[3],
        'accent': 'violet',
      });

      expect(
        restored.suggestionPanelHeight,
        AppSettings().suggestionPanelHeight,
      );
      expect(restored.inputMaxLines, AppSettings().inputMaxLines);
      expect(restored.accentId, 'violet');
    });

    test('控制器写入时也会夹取', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = AppSettingsController(const AppSettings());

      controller.setSuggestionPanelHeight(1e6);
      controller.setInputMaxLines(999);

      expect(
        controller.settings.suggestionPanelHeight,
        kSuggestionPanelHeightMax,
      );
      expect(controller.settings.inputMaxLines, kInputMaxLinesMax);

      await _flushDisk();
      controller.dispose();
    });
  });

  group('圆角与玻璃质感', () {
    test('默认值都落在滑块量程上', () {
      const settings = AppSettings();

      // 默认值必须正好压在某一档上，否则滑块会停在两个档位之间
      expect(
        (settings.radiusScale - kRadiusScaleMin) / kRadiusScaleStep,
        closeTo(10, 1e-9),
      );
      expect(
        (settings.glassThickness - kGlassThicknessMin) / kGlassThicknessStep,
        closeTo(4, 1e-9),
      );
      expect(
        (settings.glassBlur - kGlassBlurMin) / kGlassBlurStep,
        closeTo(5, 1e-9),
      );
      expect(
        (settings.glassDispersion - kGlassDispersionMin) /
            kGlassDispersionStep,
        closeTo(1, 1e-9),
      );
    });

    test('能序列化往返', () {
      const original = AppSettings(
        radiusScale: 0.8,
        glassThickness: 45,
        glassBlur: 14,
        glassDispersion: 0.06,
      );
      final restored = AppSettings.fromJson(original.toJson());

      expect(restored, original);
    });

    test('越界的值被夹回可选范围', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'radius': 9,
        'gThickness': -10,
        'gBlur': 999,
        'gDispersion': -1,
      });

      expect(restored.radiusScale, kRadiusScaleMax);
      expect(restored.glassThickness, kGlassThicknessMin);
      expect(restored.glassBlur, kGlassBlurMax);
      expect(restored.glassDispersion, kGlassDispersionMin);
    });

    test('类型损坏时只丢那一项', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'radius': '圆一点',
        'gThickness': <int>[20],
        'accent': 'violet',
      });

      expect(restored.radiusScale, AppSettings().radiusScale);
      expect(restored.glassThickness, AppSettings().glassThickness);
      expect(restored.accentId, 'violet');
    });

    test('映射到库里的玻璃参数，未暴露的字段保持"跟随默认"', () {
      const settings = AppSettings(
        glassThickness: 40,
        glassBlur: 12,
        glassDispersion: 0.05,
      );
      final glass = settings.glassSettings;

      expect(glass.thickness, 40);
      expect(glass.blur, 12);
      expect(glass.chromaticAberration, 0.05);
      // 没在设置里暴露的字段必须是 null：null 才会落到各组件自己的默认值，
      // 写成具体值会把染色、高光角度这些一起改掉
      expect(glass.glassColor, isNull);
      expect(glass.refractiveIndex, isNull);
      expect(glass.lightAngle, isNull);
    });

    testWidgets('context.radius 按系数缩放基准半径', (WidgetTester tester) async {
      final controller = AppSettingsController(
        const AppSettings(radiusScale: 1.5),
      );
      late double scaled;

      await tester.pumpWidget(
        AppSettingsScope(
          controller: controller,
          child: Builder(
            builder: (context) {
              scaled = context.radius(20);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(scaled, 30);
      controller.dispose();
    });
  });

  group('质量档位', () {
    test('默认是最高档', () {
      expect(const AppSettings().glassQualityMode, GlassQualityMode.premium);
    });

    test('每一档都能序列化往返', () {
      for (final mode in GlassQualityMode.values) {
        final restored = AppSettings.fromJson(
          AppSettings(glassQualityMode: mode).toJson(),
        );
        expect(restored.glassQualityMode, mode);
      }
    });

    test('旧版本存档没有该字段时回落到最高档', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'accent': 'violet',
      });
      expect(restored.glassQualityMode, GlassQualityMode.premium);
    });

    test('档位字段损坏时也只丢这一项', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'glass': '这不是一个档位',
        'accent': 'violet',
      });
      expect(restored.glassQualityMode, GlassQualityMode.premium);
      expect(restored.accentId, 'violet');
    });

    test('映射到库里的枚举：低两档是确定的', () {
      expect(qualityFor(GlassQualityMode.minimal), GlassQuality.minimal);
      expect(qualityFor(GlassQualityMode.standard), GlassQuality.standard);
    });

    test('纯色档不走玻璃，其余档都走', () {
      expect(usesGlass(GlassQualityMode.solid), isFalse);
      expect(usesGlass(GlassQualityMode.minimal), isTrue);
      expect(usesGlass(GlassQualityMode.standard), isTrue);
      expect(usesGlass(GlassQualityMode.premium), isTrue);
    });

    test('档位共四挡（含新增的纯色档）', () {
      expect(GlassQualityMode.values.length, 4);
      expect(GlassQualityMode.values.last, GlassQualityMode.solid);
    });

    test('最高档在跑不了着色器的平台上退回标准档', () {
      // 测试环境没有 Impeller，所以这里应当落到 standard；
      // 真机上则应当是 premium。两种情况都只允许这两个值。
      expect(<GlassQuality>{
        GlassQuality.premium,
        GlassQuality.standard,
      }, contains(qualityFor(GlassQualityMode.premium)));
    });
  });

  group('AppPalette', () {
    const accent = Color(0xFF7EF0B2);

    test('未知的 accent id 回落到第一个', () {
      expect(accentById('并不存在的id').id, kAccents.first.id);
      expect(accentById('violet').id, 'violet');
    });

    test('调色板 id 唯一', () {
      final ids = kAllAccents.map((e) => e.id).toSet();
      expect(ids.length, kAllAccents.length);
    });

    test('深色组有 9 个，且能被正确查找', () {
      expect(kDeepAccents.length, 9);
      expect(
        kAllAccents.length,
        kAccents.length + kDeepAccents.length,
      );
      expect(accentById('deepEmerald').name, '深翡翠');
    });

    test('深色组在浅色背景上对比足够', () {
      // 明度差是个粗指标，但足以拦住"深色主题色在浅色底上糊掉"这类回归
      const lightBackground = AppPalette(
        accent: Color(0xFF0E9F6E),
        isDark: false,
      );
      final bgLightness =
          HSLColor.fromColor(lightBackground.background).lightness;

      for (final option in kDeepAccents) {
        final accentLightness = HSLColor.fromColor(option.color).lightness;
        expect(
          bgLightness - accentLightness,
          greaterThan(0.25),
          reason: '${option.name} 在浅色背景上对比不足',
        );
      }
    });

    test('主题色偏暗时柔和版是提亮而不是压暗', () {
      // 深色主题色压暗会糊进背景，所以方向必须反过来
      const deep = AppPalette(accent: Color(0xFF0E9F6E), isDark: true);
      final base = HSLColor.fromColor(deep.accent).lightness;
      final soft = HSLColor.fromColor(deep.accentSoft).lightness;
      expect(soft, greaterThan(base));

      // 亮色主题色仍然压暗
      const bright = AppPalette(accent: accent, isDark: true);
      expect(
        HSLColor.fromColor(bright.accentSoft).lightness,
        lessThan(HSLColor.fromColor(bright.accent).lightness),
      );
    });

    test('accentSoft 与主题色同色相、更暗', () {
      const palette = AppPalette(accent: accent, isDark: true);
      final base = HSLColor.fromColor(palette.accent);
      final soft = HSLColor.fromColor(palette.accentSoft);

      expect(soft.hue, closeTo(base.hue, 1.0));
      expect(soft.lightness, lessThan(base.lightness));
    });

    test('浅色与深色给出不同的色阶', () {
      const dark = AppPalette(accent: accent, isDark: true);
      const light = AppPalette(accent: accent, isDark: false);

      expect(dark.textPrimary, isNot(light.textPrimary));
      expect(dark.background, isNot(light.background));
      expect(dark.overlay, isNot(light.overlay));
    });
  });

  group('HistoryController', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('新增后落盘，新控制器能读回（最新在前）', () async {
      final first = HistoryController();
      first.add('/give @a stone', true, '已给予');
      first.add('/time set day', true, '已设为白天');
      await _flushDisk();

      final second = HistoryController();
      await second.restore();

      expect(second.items.length, 2);
      expect(second.items.first.command, '/time set day');
    });

    test('恢复出来的记录不补播入场动画', () async {
      final first = HistoryController();
      first.add('/a', true, 'ok');
      await _flushDisk();

      final second = HistoryController();
      await second.restore();

      final id = second.items.first.id;
      expect(second.takeEntranceAnimation(id), isFalse);
    });

    test('新记录第一次问要播动画，第二次不再播', () {
      final controller = HistoryController();
      controller.add('/a', true, 'ok');
      final id = controller.items.first.id;

      expect(controller.takeEntranceAnimation(id), isTrue);
      expect(controller.takeEntranceAnimation(id), isFalse);
    });

    test('关闭落盘后清掉已有存档，且不再写盘', () async {
      final controller = HistoryController();
      controller.add('/a', true, 'ok');
      await _flushDisk();
      await controller.applyPersistFlag(false);

      controller.add('/b', true, 'ok');
      await _flushDisk();

      final reader = HistoryController();
      await reader.restore();
      expect(reader.items, isEmpty);
    });

    test('clear 同时清掉内存与磁盘', () async {
      final controller = HistoryController();
      controller.add('/a', true, 'ok');
      await _flushDisk();
      await controller.clear();

      expect(controller.isEmpty, isTrue);

      final reader = HistoryController();
      await reader.restore();
      expect(reader.items, isEmpty);
    });

    test('超过上限时裁掉最旧的', () {
      final controller = HistoryController();
      for (var i = 0; i < HistoryController.maxItems + 5; i++) {
        controller.add('/cmd$i', true, 'ok');
      }

      expect(controller.items.length, HistoryController.maxItems);
      expect(
        controller.items.first.command,
        '/cmd${HistoryController.maxItems + 4}',
      );
    });

    test('坏掉的单条数据被跳过，不影响其余记录', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.command_history_v1': <String>[
          '{"c":"/good","ok":true,"m":"ok"}',
          '这不是 JSON',
          '{"c":123,"m":"类型不对"}',
        ],
      });

      final controller = HistoryController();
      await controller.restore();

      expect(controller.items.length, 1);
      expect(controller.items.single.command, '/good');
    });
  });

  group('历史记录时间', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    final now = DateTime(2026, 9, 28, 15, 30);

    test('今天只给时钟', () {
      expect(formatHistoryTime(DateTime(2026, 9, 28, 9, 5), now), '09:05');
    });

    test('昨天带"昨天"', () {
      expect(formatHistoryTime(DateTime(2026, 9, 27, 23, 59), now), '昨天 23:59');
    });

    test('今年更早带月日', () {
      expect(formatHistoryTime(DateTime(2026, 1, 3, 8, 0), now), '1/3 08:00');
    });

    test('跨年带完整日期', () {
      expect(
        formatHistoryTime(DateTime(2025, 12, 31, 23, 0), now),
        '2025/12/31 23:00',
      );
    });

    test('时钟偏差造成的"未来"也按今天算', () {
      // 系统时间被回拨过时，别显示成"0 天前"这种怪东西
      expect(formatHistoryTime(DateTime(2026, 9, 28, 16, 0), now), '16:00');
    });

    test('新记录带时间，落盘读回后还在', () async {
      final controller = HistoryController();
      controller.add('/a', true, 'ok');
      final added = controller.items.first.createdAt;
      expect(added, isNotNull);
      await _flushDisk();

      final reader = HistoryController();
      await reader.restore();

      expect(
        reader.items.first.createdAt!.millisecondsSinceEpoch,
        added!.millisecondsSinceEpoch,
      );
    });

    test('老存档没有时间字段时留空，不编一个', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.command_history_v1': <String>[
          '{"c":"/old","ok":true,"m":"ok"}',
        ],
      });

      final controller = HistoryController();
      await controller.restore();

      expect(controller.items.single.createdAt, isNull);
    });
  });
}
