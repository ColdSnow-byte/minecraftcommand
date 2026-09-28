import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_settings.dart';
import 'quality_panel.dart';
import 'src/rust/api/minecraft.dart' as mc;

/// 弹出指令面板（底部抽屉），返回用户选中的指令用法；直接关掉则返回 null。
///
/// 抽成独立函数是为了让两个页面共用：控制台把返回值填进输入框，
/// 设置页没有输入框，就把它复制到剪贴板。
///
/// 指令列表由调用方提供——控制台已经在启动时拉过一次，设置页则按需拉取。
Future<String?> showCommandPalette(
  BuildContext context, {
  required List<mc.CommandInfo> commands,
}) {
  // 面板挂在 Navigator 的 Overlay 里，这里先把配色取出来，
  // 免得在 sheet 的 context 上重复依赖（两者拿到的是同一套设置）
  final palette = context.palette;

  return showModalBottomSheet<String>(
    context: context,
    // 面板是不透底的浮层，颜色得自己跟着明暗走
    backgroundColor: palette.isDark
        ? const Color(0xE6101014)
        : const Color(0xF2F6F7FA),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '指令面板 · ${commands.length} 条',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: commands.length,
              itemBuilder: (ctx, i) => _CommandTile(
                command: commands[i],
                // 把用法回传给调用方，由它决定是填入还是复制
                onTap: () => Navigator.of(ctx).pop(commands[i].usage),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 面板里的一条指令：名字 + 别名 + OP 标记，下面两行是用法和说明。
class _CommandTile extends StatelessWidget {
  const _CommandTile({required this.command, required this.onTap});

  final mc.CommandInfo command;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return QualityPanel(
      radius: 12,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(vertical: 4),
      // 列表卡片封顶在标准档，理由见 quality_panel.dart
      capQuality: GlassQuality.standard,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    '/${command.name}',
                    style: TextStyle(
                      color: palette.accent,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  if (command.aliases.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      '别名：${command.aliases.join(', ')}',
                      style: TextStyle(
                        color: palette.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (command.opOnly)
                    const _Pill(label: 'OP', color: Color(0x66FFB74D)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                command.usage,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                command.description,
                style: TextStyle(color: palette.textTertiary, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 小标签（指令面板里的 OP 标记）。
///
/// 文字固定用深色：标签底色是半透明暖橙，本身就是浅色块，
/// 白字在浅色主题下会糊掉，深色背景上也不如深字清楚。
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xFF1B1B1B),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
