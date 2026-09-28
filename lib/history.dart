import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条历史记录。
class HistoryRecord {
  const HistoryRecord({
    required this.id,
    required this.command,
    required this.success,
    required this.message,
  });

  /// 运行时自增序号，作为列表 Key 让入场动画只在插入时播一次。
  /// 不参与持久化，读回时重新分配。
  final int id;

  final String command;
  final bool success;
  final String message;
}

/// 历史记录的唯一真源。
///
/// 控制台往里写、设置页从这里清，两边共享同一个实例，所以"清空"之后
/// 控制台列表会立刻同步变空，不需要额外的回调或事件总线。
class HistoryController extends ChangeNotifier {
  HistoryController({this.persist = true});

  /// 内存里最多保留的条数
  static const maxItems = 100;

  /// 是否落盘，与设置里的"保存历史记录"开关同步。
  ///
  /// 关掉只影响磁盘：当前会话的历史照常显示，只是不再写文件，
  /// 并且已有存档会被清掉——否则用户会以为开关没生效。
  bool persist;

  final List<HistoryRecord> _items = <HistoryRecord>[];

  /// 已经播过入场动画的记录 id
  final Set<int> _animated = <int>{};

  int _seq = 0;

  /// 最新的排在最前
  List<HistoryRecord> get items => _items;

  bool get isEmpty => _items.isEmpty;

  /// 这条记录是否还需要播入场动画。
  ///
  /// 第一次问返回 true、之后都是 false，所以列表项被回收后重建时不会再播，
  /// 往回滚动不会看到历史"重新浮现"。
  bool takeEntranceAnimation(int id) => _animated.add(id);

  /// 启动时从磁盘恢复一次。
  Future<void> restore() async {
    final saved = await HistoryStore.load();
    if (saved.isEmpty) return;
    _items
      ..clear()
      ..addAll(saved);
    _seq = saved.length;
    // 恢复出来的记录直接静止显示，不补播动画
    _animated.addAll(saved.map((e) => e.id));
    notifyListeners();
  }

  /// 记一条新执行的指令。
  void add(String command, bool success, String message) {
    _items.insert(
      0,
      HistoryRecord(
        id: _seq++,
        command: command,
        success: success,
        message: message,
      ),
    );
    if (_items.length > maxItems) {
      _items.removeRange(maxItems, _items.length);
    }
    notifyListeners();
    _persist();
  }

  /// 清空（内存 + 磁盘）。
  Future<void> clear() async {
    if (_items.isEmpty) return;
    _items.clear();
    _animated.clear();
    notifyListeners();
    await HistoryStore.clear();
  }

  /// 设置页切换"保存历史记录"时调用。
  Future<void> applyPersistFlag(bool value) async {
    persist = value;
    if (!value) await HistoryStore.clear();
  }

  void _persist() {
    if (!persist) return;
    unawaited(HistoryStore.save(_items));
  }
}

/// 历史记录的磁盘读写。
class HistoryStore {
  static const _key = 'command_history_v1';

  static Future<List<HistoryRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const <String>[];
    final out = <HistoryRecord>[];
    for (var i = 0; i < raw.length; i++) {
      final record = _decode(raw[i], i);
      if (record != null) out.add(record);
    }
    return out;
  }

  static Future<void> save(Iterable<HistoryRecord> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, items.map(_encode).toList());
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static String _encode(HistoryRecord r) => jsonEncode(<String, dynamic>{
    'c': r.command,
    'ok': r.success,
    'm': r.message,
  });

  /// 解析失败返回 null，由调用方跳过——单条坏数据不该让整段历史消失。
  static HistoryRecord? _decode(String raw, int id) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final command = json['c'];
      final message = json['m'];
      if (command is! String || message is! String) return null;
      return HistoryRecord(
        id: id,
        command: command,
        success: json['ok'] == true,
        message: message,
      );
    } on FormatException {
      return null;
    }
  }
}

/// 把 [HistoryController] 注入组件树。
///
/// 控制台和设置页都从这里取同一个实例，所以设置页清空后，
/// 控制台的列表会通过 [ChangeNotifier] 自动重建。
class HistoryScope extends InheritedNotifier<HistoryController> {
  const HistoryScope({
    super.key,
    required HistoryController controller,
    required super.child,
  }) : super(notifier: controller);

  static HistoryController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<HistoryScope>();
    assert(scope != null, '组件树上没有 HistoryScope，检查 AppShell 是否包了它');
    return scope!.notifier!;
  }
}

/// 取用历史记录的语法糖。
extension HistoryContext on BuildContext {
  HistoryController get history => HistoryScope.of(this);
}
