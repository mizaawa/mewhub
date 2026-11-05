import 'dart:math' as math;

/// Small, safe arithmetic evaluator (no code execution).
/// Supports + - * / % ^, parentheses, unary minus, and common functions.
class Calculator {
  Calculator(this._src);
  final String _src;
  int _i = 0;

  static num eval(String expr) {
    final c = Calculator(expr.replaceAll(' ', '').replaceAll('×', '*').replaceAll('÷', '/'));
    final v = c._expr();
    if (c._i < c._src.length) throw FormatException('Unexpected "${c._src[c._i]}" at ${c._i}');
    return v;
  }

  String? get _peek => _i < _src.length ? _src[_i] : null;

  num _expr() {
    var v = _term();
    while (_peek == '+' || _peek == '-') {
      final op = _src[_i++];
      final r = _term();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  num _term() {
    var v = _factor();
    while (_peek == '*' || _peek == '/' || _peek == '%') {
      final op = _src[_i++];
      final r = _factor();
      v = switch (op) {
        '*' => v * r,
        '/' => v / r,
        _ => v % r,
      };
    }
    return v;
  }

  num _factor() {
    final base = _unary();
    if (_peek == '^') {
      _i++;
      return math.pow(base, _factor());
    }
    return base;
  }

  num _unary() {
    if (_peek == '-') {
      _i++;
      return -_unary();
    }
    if (_peek == '+') {
      _i++;
      return _unary();
    }
    return _primary();
  }

  static const _fns = {
    'sqrt': math.sqrt,
    'sin': math.sin,
    'cos': math.cos,
    'tan': math.tan,
    'asin': math.asin,
    'acos': math.acos,
    'atan': math.atan,
    'ln': math.log,
    'exp': math.exp,
  };

  num _primary() {
    final ch = _peek;
    if (ch == null) throw const FormatException('Unexpected end');
    if (ch == '(') {
      _i++;
      final v = _expr();
      if (_peek != ')') throw const FormatException('Missing )');
      _i++;
      return v;
    }
    final num = RegExp(r'\d+(\.\d+)?([eE][-+]?\d+)?').matchAsPrefix(_src, _i);
    if (num != null) {
      _i = num.end;
      return double.parse(num.group(0)!);
    }
    final id = RegExp(r'[a-zA-Z]+').matchAsPrefix(_src, _i);
    if (id != null) {
      final name = id.group(0)!.toLowerCase();
      _i = id.end;
      if (name == 'pi') return math.pi;
      if (name == 'e') return math.e;
      if (name == 'abs' || name == 'log' || _fns.containsKey(name)) {
        if (_peek != '(') throw FormatException('Expected ( after $name');
        _i++;
        final arg = _expr();
        if (_peek != ')') throw const FormatException('Missing )');
        _i++;
        if (name == 'abs') return arg.abs();
        if (name == 'log') return math.log(arg) / math.ln10;
        return _fns[name]!(arg);
      }
      throw FormatException('Unknown identifier $name');
    }
    throw FormatException('Unexpected "$ch"');
  }
}
