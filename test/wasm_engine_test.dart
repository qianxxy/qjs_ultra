// ignore_for_file: cascade_invocations
import 'package:qjs_ultra/qjs_ultra.dart';
import 'package:test/test.dart';

import 'engine_test.dart' show resolveLibPath;

/// WebAssembly 真实引擎测试（防假阳性回归）。
///
/// **背景**：2026-10-10 之前 CI 的 dart-check 零 wasm 用例——Windows dll
/// 上 wasm 全坏（最小模块实例化即失败）而 CI 恒绿。根因是 MinGW PE 无
/// ELF mergeable .rodata，gcc LTO 常量传播破坏 wasm3 错误码指针同一性
/// 比较（LinkLibC 的 lookup-failure 抑制失效）；修复见
/// native/quickjs/ext/CMakeLists.txt 的 wasm3 -fno-lto 段。
///
/// 用例全部手写 wasm 二进制（无 emscripten 依赖），覆盖：
///   1. 最小模块实例化 + 导出调用（i32）
///   2. f64 常量返回（浮点转换路径）
///   3. Memory initial/grow/buffer.byteLength 读写语义（emscripten 依赖 growth）
///   4. 带导入函数 + 多导出的中等模块（JS 回调进 wasm + 参数/返回传递）
///
/// 库来源与 engine_test.dart 一致：QJS_ULTRA_LIB 或仓内约定路径。
void main() {
  final libPath = resolveLibPath();
  if (libPath == null) {
    test('（跳过）未找到 quickjs_bridge 动态库', () {},
        skip: '未找到动态库：设置 QJS_ULTRA_LIB 或放置 native/<平台>/<arch>/');
    return;
  }

  late QuickjsEngine engine;

  setUp(() {
    engine = QuickjsEngine.createWith(const JsEngineConfig(), libPath: libPath);
  });

  tearDown(() {
    engine.dispose();
  });

  group('WebAssembly（真实 so，防假阳性）', () {
    test('最小模块：实例化 + 导出调用返回 42', () {
      // (module (func (export "f") (result i32) i32.const 42))
      final r = engine.evaluate('''
const bytes = new Uint8Array([
  0x00,0x61,0x73,0x6d, 0x01,0x00,0x00,0x00,
  0x01,0x05,0x01,0x60,0x00,0x01,0x7f,
  0x03,0x02,0x01,0x00,
  0x07,0x05,0x01,0x01,0x66,0x00,0x00,
  0x0a,0x06,0x01,0x04,0x00,0x41,0x2a,0x0b,
]);
const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes));
inst.exports.f();
''');
      // 坏 dll 在 Instance 构造就抛 "function lookup failed"（LinkLibC
      // 抑制失效）——这正是 2026-10-10 Windows 产物的故障形态。
      expect(r, 42, reason: '最小 wasm 模块应可实例化并调用');
    });

    test('f64 常量返回（浮点栈转换路径）', () {
      // (module (func (export "pi") (result f64) f64.const 3.14))
      final r = engine.evaluate('''
const bytes = new Uint8Array([
  0x00,0x61,0x73,0x6d, 0x01,0x00,0x00,0x00,
  0x01,0x05,0x01,0x60,0x00,0x01,0x7c,
  0x03,0x02,0x01,0x00,
  0x07,0x06,0x01,0x02,0x70,0x69,0x00,0x00,
  0x0a,0x0d,0x01,0x0b,0x00,0x44,
  0x1f,0x85,0xeb,0x51,0xb8,0x1e,0x09,0x40,
  0x0b,
]);
new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports.pi();
''');
      expect((r as num).toDouble(), closeTo(3.14, 1e-9));
    });

    test('Memory grow 语义：旧页数 + byteLength + 跨页读写', () {
      // 8 页 grow 16 页 → 24 页；grow 返回旧页数 8；首尾字节读写往返
      final r = engine.evaluate('''
const mem = new WebAssembly.Memory({initial: 8});
const old = mem.grow(16);
const v = new Uint8Array(mem.buffer);
v[0] = 41; v[v.length - 1] = 1;
[mem.buffer.byteLength, old, v[0], v[v.length - 1]].join(',');
''');
      final parts = (r as String).split(',');
      expect(int.parse(parts[0]), 24 * 65536,
          reason: 'grow 后 byteLength 应为 24 页');
      expect(int.parse(parts[1]), 8, reason: 'grow 返回旧页数');
      expect(parts[2], '41');
      expect(parts[3], '1');
    });

    test('中等模块：JS 导入函数 + 多导出 + 参数传递', () {
      // (module
      //   (import "env" "mul2" (func $mul2 (param i32) (result i32)))
      //   (func (export "add") (param i32 i32) (result i32)
      //     local.get 0 local.get 1 i32.add)
      //   (func (export "useImport") (param i32) (result i32)
      //     local.get 0 call $mul2))
      final r = engine.evaluate('''
const bytes = new Uint8Array([
  0x00,0x61,0x73,0x6d, 0x01,0x00,0x00,0x00,
  0x01,0x0c,0x02,0x60,0x01,0x7f,0x01,0x7f,0x60,0x02,0x7f,0x7f,0x01,0x7f,
  0x02,0x0c,0x01,0x03,0x65,0x6e,0x76,0x04,0x6d,0x75,0x6c,0x32,0x00,0x00,
  0x03,0x03,0x02,0x01,0x00,
  0x07,0x13,0x02,0x03,0x61,0x64,0x64,0x00,0x01,
              0x09,0x75,0x73,0x65,0x49,0x6d,0x70,0x6f,0x72,0x74,0x00,0x02,
  0x0a,0x10,0x02,
        0x07,0x00,0x20,0x00,0x20,0x01,0x6a,0x0b,
        0x06,0x00,0x20,0x00,0x10,0x00,0x0b,
]);
const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
  env: { mul2: (x) => x * 2 },
});
[inst.exports.add(3, 4), inst.exports.useImport(21)].join(',');
''');
      // add 走 wasm 内部算术；useImport 走 JS 回调（绑定层 qjs_wasm_imported_func）
      expect(r, '7,42');
    });

    test('WebAssembly.validate / Module.exports 反射', () {
      final r = engine.evaluate('''
const bytes = new Uint8Array([
  0x00,0x61,0x73,0x6d, 0x01,0x00,0x00,0x00,
  0x01,0x05,0x01,0x60,0x00,0x01,0x7f,
  0x03,0x02,0x01,0x00,
  0x07,0x05,0x01,0x01,0x66,0x00,0x00,
  0x0a,0x06,0x01,0x04,0x00,0x41,0x2a,0x0b,
]);
JSON.stringify(WebAssembly.Module.exports(new WebAssembly.Module(bytes)))
  + '|' + WebAssembly.validate(bytes) + '|' + WebAssembly.validate(new Uint8Array([1,2,3]));
''');
      expect(r,
          '[{"kind":"function","name":"f"}]|true|false');
    });
  });
}
