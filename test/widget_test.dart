import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minecraftcommand/main.dart';

void main() {
  // UI 依赖 RustLib（flutter_rust_bridge）原生库，
  // 无法在纯 Dart 测试环境中 pump，这里做基本的类型与常量检查。
  test('app widget type exists', () {
    const app = MinecraftCommandApp();
    expect(app, isA<MinecraftCommandApp>());
  });

  // MaterialApp 会用 _errorTextStyle（黄色双下划线）包裹整个应用，
  // Overlay 条目（Toast）不在 Material 内部，需要 builder 提供正常样式。
  testWidgets('overlay entries inherit a normal DefaultTextStyle', (WidgetTester tester) async {
    TextStyle? overlayStyle;
    TextStyle? pageStyle;

    await tester.pumpWidget(
      MaterialApp(
        builder: appShellBuilder,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    // 页面内（Material 内部）的样式
    final scaffoldContext = tester.element(find.byType(Scaffold));
    pageStyle = DefaultTextStyle.of(scaffoldContext).style;

    // Overlay 条目中的样式（Toast 所在位置）
    final overlay = Overlay.of(scaffoldContext);
    final entry = OverlayEntry(
      builder: (context) {
        overlayStyle = DefaultTextStyle.of(context).style;
        return const SizedBox.shrink();
      },
    );
    overlay.insert(entry);
    await tester.pump();

    expect(overlayStyle, isNotNull);
    // 不应出现 MaterialApp 兜底样式的黄色双下划线
    expect(overlayStyle!.decoration, TextDecoration.none);
    expect(overlayStyle!.decorationColor, Colors.transparent);
    expect(overlayStyle!.fontSize, 15);
    // 兜底样式是 48px 等宽红色，这里必须不是它
    expect(overlayStyle!.fontSize, isNot(48));

    // 页面内样式不受影响（由 Material 提供）
    expect(pageStyle.color, isNot(const Color(0xD0FF0000)));
  });
}
