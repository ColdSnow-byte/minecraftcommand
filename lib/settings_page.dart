import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_palette.dart';
import 'app_settings.dart';
import 'command_palette.dart';
import 'glass.dart';
import 'history.dart';
import 'quality_panel.dart';
import 'src/rust/api/minecraft.dart' as mc;

/// 设置页：明暗模式、主题色、历史记录开关、背景图与两个视觉滑块。
///
/// 所有改动都即时生效并自动落盘——没有"保存"按钮，改完直接返回控制台即可。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final settings = context.appSettings;
    final app = context.settingsController;
    final history = context.history;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '设置',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '外观与偏好',
                style: TextStyle(color: palette.textTertiary, fontSize: 12),
              ),
            ],
          ),
        ),

        // ─────────── 外观 ───────────
        _SectionCard(
          title: '外观',
          icon: Icons.contrast_rounded,
          children: <Widget>[
            _RowLabel(text: '明暗模式'),
            const SizedBox(height: 10),
            _BrightnessSelector(
              value: settings.brightnessMode,
              onSelect: app.setBrightnessMode,
            ),
            const SizedBox(height: 18),
            _RowLabel(text: '主题色'),
            const SizedBox(height: 4),
            Text(
              '决定提示文本、状态徽章与选中态的颜色',
              style: TextStyle(color: palette.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 12),
            _AccentSwatches(
              options: kAccents,
              selectedId: settings.accentId,
              onSelect: app.setAccent,
            ),
            const SizedBox(height: 14),
            Text(
              '深色（浅色模式下对比更清楚）',
              style: TextStyle(color: palette.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 10),
            _AccentSwatches(
              options: kDeepAccents,
              selectedId: settings.accentId,
              onSelect: app.setAccent,
            ),
            const SizedBox(height: 18),
            _RowLabel(text: '质量等级'),
            const SizedBox(height: 4),
            Text(
              '越高的档位越接近 iOS 26 的观感，也更吃 GPU；改完立即生效',
              style: TextStyle(color: palette.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 10),
            _QualitySelector(
              value: settings.glassQualityMode,
              onSelect: app.setGlassQualityMode,
            ),
            _HairLine(),
            _SwitchRow(
              title: '光球环绕',
              subtitle: '在每个玻璃面板的边缘绕行一颗拖尾光球（纯装饰，默认关闭）',
              value: settings.orbitEnabled,
              onChanged: app.setOrbitEnabled,
            ),
          ],
        ),

        // ─────────── 历史记录 ───────────
        _SectionCard(
          title: '历史记录',
          icon: Icons.history_rounded,
          children: <Widget>[
            _SwitchRow(
              title: '保存历史记录',
              subtitle: '关闭后不再写入磁盘，并清空已有存档',
              value: settings.persistHistory,
              onChanged: (value) {
                app.setPersistHistory(value);
                history.applyPersistFlag(value);
              },
            ),
            _HairLine(),
            _ActionRow(
              title: '清空历史记录',
              subtitle: history.isEmpty
                  ? '当前没有记录'
                  : '当前有 ${history.items.length} 条，清空后无法恢复',
              enabled: !history.isEmpty,
              destructive: true,
              onTap: () => _confirmClear(context),
            ),
          ],
        ),

        // ─────────── 背景 ───────────
        _SectionCard(
          title: '背景',
          icon: Icons.wallpaper_rounded,
          children: <Widget>[
            _ActionRow(
              title: settings.backgroundImagePath == null ? '选择背景图片' : '更换背景图片',
              subtitle: settings.backgroundImagePath == null
                  ? '图片会复制到应用目录，原图删除后依然可用'
                  : '已应用自定义背景',
              onTap: () => _pickBackground(context),
            ),
            if (settings.backgroundImagePath != null) ...<Widget>[
              _HairLine(),
              _ActionRow(
                title: '移除背景图片',
                subtitle: '恢复为动态流光背景',
                destructive: true,
                onTap: () => _removeBackground(context),
              ),
            ],
            _HairLine(),
            _SliderRow(
              title: '模糊',
              value: settings.backgroundBlur,
              // 没选图时模糊/压暗没有作用对象，灰掉避免误解
              enabled: settings.backgroundImagePath != null,
              onChanged: app.setBackgroundBlur,
            ),
            _SliderRow(
              title: '压暗',
              value: settings.backgroundDim,
              enabled: settings.backgroundImagePath != null,
              onChanged: app.setBackgroundDim,
            ),
          ],
        ),

        // ─────────── 指令手册 ───────────
        _SectionCard(
          title: '指令手册',
          icon: Icons.menu_book_rounded,
          children: <Widget>[
            _ActionRow(
              title: '打开指令面板',
              subtitle: '浏览全部指令与用法，点任意一条即复制到剪贴板',
              onTap: () => _openCommandPalette(context),
            ),
          ],
        ),

        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Text(
            '设置会自动保存',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }

  /// 选背景图。注意 await 之前就把 controller / messenger 取出来，
  /// await 之后不再碰 `context`（否则会触发 use_build_context_synchronously）。
  Future<void> _pickBackground(BuildContext context) async {
    final app = context.settingsController;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await BackgroundImageStore.pick();
      if (path == null) return; // 用户取消
      app.setBackgroundImage(path);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('选择图片失败：$error')));
    }
  }

  Future<void> _removeBackground(BuildContext context) async {
    final app = context.settingsController;
    final old = context.appSettings.backgroundImagePath;
    app.setBackgroundImage(null);
    await BackgroundImageStore.remove(old);
  }

  /// 指令面板。
  ///
  /// 设置页没有输入框，所以选中的用法直接进剪贴板——用户多半是要粘到
  /// 游戏里或聊天窗里用，复制比"填入输入框"更顺手。
  Future<void> _openCommandPalette(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 设置页是首次打开时才拉列表；控制台那边有启动预加载
      final commands = await mc.listCommands();
      if (!context.mounted) return;
      final usage = await showCommandPalette(context, commands: commands);
      if (usage == null) return; // 用户直接关掉了面板
      await Clipboard.setData(ClipboardData(text: usage));
      messenger.showSnackBar(SnackBar(content: Text('已复制：$usage')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('打开指令面板失败：$error')));
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    final history = context.history;
    final palette = context.palette;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.isDark
            ? const Color(0xFF1B1F26)
            : const Color(0xFFFDFDFF),
        title: const Text('清空历史记录'),
        content: Text(
          '将删除全部 ${history.items.length} 条执行记录，此操作无法撤销。',
          style: TextStyle(color: palette.textSecondary, fontSize: 13.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: palette.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('清空', style: TextStyle(color: palette.errorIcon)),
          ),
        ],
      ),
    );

    if (confirmed == true) await history.clear();
  }
}

// ─────────────────────────── 布局零件 ───────────────────────────

/// 一个设置分组：玻璃卡片 + 标题。
///
/// [GlassCard] 自带 16px 内边距，所以这里不再补 padding。
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return QualityPanel(
      radius: 12,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 14),
      // 列表卡片封顶在标准档，理由见 quality_panel.dart
      capQuality: GlassQuality.standard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 15, color: palette.accent),
              const SizedBox(width: 7),
              Text(
                title,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

/// 行内的项目标题
class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.text, this.subtitle});

  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          text,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 3),
          Text(
            subtitle!,
            style: TextStyle(color: palette.textMuted, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

/// 组内的细分隔线
class _HairLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Divider(
        height: 1,
        thickness: 1,
        color: palette.textMuted.withValues(alpha: 0.12),
      ),
    );
  }
}

/// 明暗模式三段选择器。用主题色淡染指示选中项，避免额外引入一套配色。
class _BrightnessSelector extends StatelessWidget {
  const _BrightnessSelector({required this.value, required this.onSelect});

  final AppBrightnessMode value;
  final ValueChanged<AppBrightnessMode> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.textMuted.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          for (final mode in AppBrightnessMode.values)
            Expanded(
              child: _Segment(
                label: mode.label,
                icon: mode.icon,
                selected: mode == value,
                onTap: () => onSelect(mode),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? palette.accentHighlight : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 16,
                color: selected ? palette.accent : palette.textMuted,
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? palette.accent : palette.textMuted,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 调色板：一排可选的主题色圆点。
class _AccentSwatches extends StatelessWidget {
  const _AccentSwatches({
    required this.options,
    required this.selectedId,
    required this.onSelect,
  });

  final List<AccentOption> options;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (final option in options)
          _AccentDot(
            option: option,
            selected: option.id == selectedId,
            onTap: () => onSelect(option.id),
          ),
      ],
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final AccentOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: option.name,
      selected: selected,
      button: true,
      child: Tooltip(
        message: option.name,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: option.color.withValues(alpha: selected ? 0.26 : 0.10),
              border: Border.all(
                color: selected
                    ? option.color
                    : option.color.withValues(alpha: 0.35),
                width: selected ? 2.2 : 1,
              ),
            ),
            child: Center(
              // 选中时圆点变大，配合外圈形成"被按下"的实心感
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: selected ? 16 : 13,
                height: selected ? 16 : 13,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: option.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 质量档位选择器：三行选项，每行是「名称 + 说明 + 选中标记」。
///
/// 这里没用分段控件：三档的说明文字长短不一，塞进等宽单元格会挤成一团，
/// 而且用户需要读到"较吃 GPU / 最省电"这类差异才能做判断。
class _QualitySelector extends StatelessWidget {
  const _QualitySelector({required this.value, required this.onSelect});

  final GlassQualityMode value;
  final ValueChanged<GlassQualityMode> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (final mode in GlassQualityMode.values)
          _QualityOption(
            mode: mode,
            selected: mode == value,
            onTap: () => onSelect(mode),
          ),
      ],
    );
  }
}

/// 质量档位里的一个选项。
class _QualityOption extends StatelessWidget {
  const _QualityOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final GlassQualityMode mode;
  final bool selected;
  final VoidCallback onTap;

  static const _duration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: _duration,
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? palette.accentHighlight : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    AnimatedDefaultTextStyle(
                      duration: _duration,
                      style: TextStyle(
                        color: selected ? palette.accent : palette.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                      child: Text(mode.label),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      mode.description,
                      style: TextStyle(color: palette.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              AnimatedSwitcher(
                duration: _duration,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.7, end: 1).animate(animation),
                    child: child,
                  ),
                ),
                child: Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  // Key 随选中态变化，切换时重播一次缩放淡入
                  key: ValueKey<bool>(selected),
                  size: 18,
                  color: selected ? palette.accent : palette.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行开关。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: <Widget>[
        Expanded(
          child: _RowLabel(text: title, subtitle: subtitle),
        ),
        const SizedBox(width: 12),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: palette.accent,
          activeTrackColor: palette.accent.withValues(alpha: 0.35),
          inactiveThumbColor: palette.textMuted,
          inactiveTrackColor: palette.textMuted.withValues(alpha: 0.18),
        ),
      ],
    );
  }
}

/// 一行可点击的动作（如"清空历史记录"）。禁用时整体降透明度。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    this.destructive = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  /// 危险操作用错误色标注
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final titleColor = !enabled
        ? palette.textMuted
        : destructive
        ? palette.errorIcon
        : palette.textPrimary;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(color: palette.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: enabled
                  ? palette.textMuted
                  : palette.textMuted.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行滑块：标题 + 百分比读数 + 轨道。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final double value;
  final ValueChanged<double> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final labelColor = enabled ? palette.textPrimary : palette.textMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                color: labelColor,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '${(value * 100).round()}%',
              style: TextStyle(
                color: enabled ? palette.accent : palette.textMuted,
                fontSize: 12,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            activeTrackColor: palette.accent,
            inactiveTrackColor: palette.textMuted.withValues(alpha: 0.18),
            thumbColor: palette.accent,
            overlayColor: palette.accent.withValues(alpha: 0.14),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(value: value, onChanged: enabled ? onChanged : null),
        ),
      ],
    );
  }
}
