import 'dart:math' as math;

/// A bounded mathematical expression tree. No scripts, remote code or eval.
///
/// Supports x, pi, e, arithmetic, powers, implicit multiplication (2x), and
/// common single-argument functions. Domain errors remain NaN / infinity so a
/// renderer can leave a gap instead of drawing across an asymptote.
class PlotExpression {
  PlotExpression._(this.source, this._root);

  static const maxLength = 512;
  final String source;
  final _Node _root;

  factory PlotExpression.compile(String expression) {
    final source = expression.trim();
    if (source.isEmpty || source.length > maxLength) {
      throw const FormatException('An expression must contain 1–512 characters.');
    }
    var normalized = source
        .toLowerCase()
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('−', '-')
        .replaceAll('π', 'pi');
    normalized = normalized.replaceFirst(RegExp(r'^y\s*=\s*'), '');
    return PlotExpression._(source, _Parser(normalized).parse());
  }

  double evaluate(double x) => _root.evaluate(x);
}

sealed class _Node {
  const _Node();
  double evaluate(double x);
}

class _Constant extends _Node {
  const _Constant(this.value);
  final double value;

  @override
  double evaluate(double x) => value;
}

class _Variable extends _Node {
  const _Variable();

  @override
  double evaluate(double x) => x;
}

class _Unary extends _Node {
  const _Unary(this.operand, this.negate);
  final _Node operand;
  final bool negate;

  @override
  double evaluate(double x) => negate ? -operand.evaluate(x) : operand.evaluate(x);
}

class _Binary extends _Node {
  const _Binary(this.left, this.operator, this.right);
  final _Node left;
  final String operator;
  final _Node right;

  @override
  double evaluate(double x) {
    final a = left.evaluate(x);
    final b = right.evaluate(x);
    return switch (operator) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      '/' => a / b,
      '%' => a % b,
      '^' => math.pow(a, b).toDouble(),
      _ => double.nan,
    };
  }
}

class _Function extends _Node {
  const _Function(this.function, this.argument);
  final double Function(double) function;
  final _Node argument;

  @override
  double evaluate(double x) => function(argument.evaluate(x));
}

class _Parser {
  _Parser(this.source);
  final String source;
  int _index = 0;
  int _depth = 0;
  int _nodes = 0;

  static final _number = RegExp(r'(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?');
  static final _identifier = RegExp(r'[a-z]+');
  static final _functions = <String, double Function(double)>{
    'sin': math.sin,
    'cos': math.cos,
    'tan': math.tan,
    'asin': math.asin,
    'acos': math.acos,
    'atan': math.atan,
    'sqrt': math.sqrt,
    'ln': math.log,
    'log': (value) => math.log(value) / math.ln10,
    'exp': math.exp,
    'abs': (value) => value.abs(),
    'floor': (value) => value.isFinite ? value.floorToDouble() : value,
    'ceil': (value) => value.isFinite ? value.ceilToDouble() : value,
  };

  String get _peek {
    while (_index < source.length && RegExp(r'\s').hasMatch(source[_index])) {
      _index++;
    }
    return _index < source.length ? source[_index] : '';
  }

  bool _take(String token) {
    if (_peek != token) return false;
    _index++;
    return true;
  }

  T _node<T extends _Node>(T value) {
    if (++_nodes > 192) throw const FormatException('Expression is too complex.');
    return value;
  }

  _Node _nested(_Node Function() parse) {
    if (++_depth > 48) throw const FormatException('Expression is nested too deeply.');
    final result = parse();
    _depth--;
    return result;
  }

  _Node parse() {
    final result = _sum();
    if (_peek.isNotEmpty) throw FormatException('Unexpected "$_peek" at position ${_index + 1}.');
    return result;
  }

  _Node _sum() {
    var result = _product();
    while (_peek == '+' || _peek == '-') {
      final operator = _peek;
      _index++;
      result = _node(_Binary(result, operator, _product()));
    }
    return result;
  }

  _Node _product() {
    var result = _unary();
    while (true) {
      final next = _peek;
      if (next == '*' || next == '/' || next == '%') {
        _index++;
        result = _node(_Binary(result, next, _unary()));
      } else if (next == '(' || RegExp(r'[a-z]').hasMatch(next)) {
        result = _node(_Binary(result, '*', _unary()));
      } else {
        return result;
      }
    }
  }

  // Unary signs bind less tightly than exponentiation: -x^2 is -(x^2),
  // while 2^-2 and right-associative 2^3^2 are both accepted.
  _Node _unary() {
    if (_take('-')) return _node(_Unary(_nested(_unary), true));
    if (_take('+')) return _node(_Unary(_nested(_unary), false));
    return _power();
  }

  _Node _power() {
    final result = _primary();
    if (_take('^')) return _node(_Binary(result, '^', _nested(_unary)));
    return result;
  }

  _Node _primary() {
    if (_take('(')) {
      final result = _nested(_sum);
      if (!_take(')')) throw const FormatException('Missing closing parenthesis.');
      return result;
    }
    if (_peek.isEmpty) throw const FormatException('Expected a number, x, or a function.');
    final number = _number.matchAsPrefix(source, _index);
    if (number != null) {
      _index = number.end;
      final value = double.parse(number.group(0)!);
      if (!value.isFinite) throw const FormatException('Numeric constants must be finite.');
      return _node(_Constant(value));
    }
    final identifier = _identifier.matchAsPrefix(source, _index);
    if (identifier != null) {
      _index = identifier.end;
      final name = identifier.group(0)!;
      if (name == 'x') return _node(const _Variable());
      if (name == 'pi') return _node(const _Constant(math.pi));
      if (name == 'e') return _node(const _Constant(math.e));
      final function = _functions[name];
      if (function == null) throw FormatException('Unknown function or variable "$name".');
      if (!_take('(')) throw FormatException('Expected ( after $name.');
      final argument = _nested(_sum);
      if (!_take(')')) throw const FormatException('Missing closing parenthesis.');
      return _node(_Function(function, argument));
    }
    throw FormatException('Unexpected "$_peek" at position ${_index + 1}.');
  }
}
