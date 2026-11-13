import 'dart:math' as math;

/// A bounded mathematical expression tree. No scripts, remote code or eval.
///
/// Supports x, pi, e, arithmetic, powers, implicit multiplication (2x), and
/// common single-argument functions. Domain errors remain NaN / infinity so a
/// renderer can leave a gap instead of drawing across an asymptote.
///
/// An entry may name its curve the way a textbook does: `f(x) = x^2`,
/// `y_1 = 2x + 1` or `AB: y = -x + 3`. `x = 2` is a vertical line, and one `±`
/// draws both branches of a conic, as in `y = ±sqrt(9 - x^2)` for a circle.
class PlotExpression {
  PlotExpression._(this.source, this._root, {this.name, this.label, this.verticalX, this.plusMinus = false});

  static const maxLength = 512;
  final String source;
  final _Node _root;

  /// The left-hand side as written, such as `f(x)` or `y_1`; null when the
  /// entry is a bare expression or a vertical line.
  final String? name;

  /// A curve label written before a colon, such as `l` in `l: y = x`.
  final String? label;

  /// The x coordinate of a vertical line written as `x = c`.
  final double? verticalX;

  /// Whether the expression contains `±` and so has a lower branch too.
  final bool plusMinus;

  bool get isVertical => verticalX != null;

  /// A horizontal line such as `y = 1`: its value does not depend on x.
  bool get isConstant => !isVertical && !_root.usesX;

  /// Contains sin, cos or tan of x, so the x axis reads best in multiples of π.
  bool get isPeriodic => _root.periodic;

  // `l:`, `l_1：` or `AB:` before the equation names the curve, like
  // "l₁: y = 2x + 1" or the line through A and B.
  static final _labelPrefix = RegExp(r"^([A-Za-z]{1,3}(?:_?\{?\d{1,2}\}?)?'{0,2})\s*:\s*");
  // `y =`, `y_1 =`, `f(x) =`, `g'(x) =` or `x =` before the expression.
  static final _lhsPrefix = RegExp(
    r"^(?:([yY](?:_?\{?\d{1,2}\}?)?)|([A-Za-z](?:_?\{?\d{1,2}\}?)?'{0,2})\s*\(\s*[xX]\s*\)|([xX]))\s*=\s*",
  );

  factory PlotExpression.compile(String expression) {
    final source = expression.trim();
    if (source.isEmpty || source.length > maxLength) {
      throw const FormatException('An expression must contain 1–512 characters.');
    }
    var rest = source
        .replaceAll('×', '*')
        .replaceAll('·', '*')
        .replaceAll('÷', '/')
        .replaceAll('−', '-')
        .replaceAll('π', 'pi')
        .replaceAll('²', '^2')
        .replaceAll('³', '^3')
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll('＝', '=')
        .replaceAll('：', ':')
        .replaceAll(r'\pm', '±');
    String? label;
    final labelMatch = _labelPrefix.firstMatch(rest);
    if (labelMatch != null) {
      label = _plainName(labelMatch.group(1)!);
      rest = rest.substring(labelMatch.end);
    }
    String? name;
    var vertical = false;
    final lhs = _lhsPrefix.firstMatch(rest);
    if (lhs != null) {
      if (lhs.group(3) != null) {
        vertical = true;
      } else if (lhs.group(1) != null) {
        name = _plainName(lhs.group(1)!);
      } else {
        name = '${_plainName(lhs.group(2)!)}(x)';
      }
      rest = rest.substring(lhs.end);
    }
    final parser = _Parser(rest.toLowerCase());
    final root = parser.parse();
    if (!vertical) {
      return PlotExpression._(source, root, name: name, label: label, plusMinus: parser.plusMinus > 0);
    }
    if (root.usesX) throw const FormatException('Write a vertical line as x = a number, for example x = 2.');
    if (parser.plusMinus > 0) {
      throw const FormatException('Write each vertical line separately, for example x = 2 and x = -2.');
    }
    final value = root.evaluate(0, 1);
    if (!value.isFinite || value.abs() > 1000000) {
      throw const FormatException('A vertical line needs a finite x between -1000000 and 1000000.');
    }
    return PlotExpression._(source, root, label: label, verticalX: value);
  }

  // "y_{1}" and "y1" are both stored as "y_1".
  static String _plainName(String raw) {
    final match = RegExp(r"^([A-Za-z])_?\{?(\d*)\}?('*)$").firstMatch(raw);
    if (match == null) return raw;
    final digits = match.group(2)!;
    return '${match.group(1)}${digits.isEmpty ? '' : '_$digits'}${match.group(3)}';
  }

  /// y at [x]; with `±`, [lower] picks the branch with the minus sign.
  double evaluate(double x, {bool lower = false}) => isVertical ? double.nan : _root.evaluate(x, lower ? -1 : 1);

  /// The right-hand side as LaTeX, such as `x^{2}-4x+3`.
  String get tex => _root.tex();

  /// The right-hand side with Unicode math symbols, such as `x² − 4x + 3`.
  String get text => _root.text();
}

/// `y_1` → `y_{1}` and `f'(x)` unchanged, for a name stored by [PlotExpression].
String plotNameTex(String name) => name.replaceAllMapped(RegExp(r'_(\d+)'), (m) => '_{${m[1]}}');

/// `y_1` → `y₁` and `A'` → `A′`, for a name stored by [PlotExpression].
String plotNameText(String name) => name
    .replaceAllMapped(RegExp(r'_\{?(\d+)\}?'), (m) => m[1]!.split('').map((d) => _subscripts[d]).join())
    .replaceAll("'", '′');

const _subscripts = {
  '0': '₀',
  '1': '₁',
  '2': '₂',
  '3': '₃',
  '4': '₄',
  '5': '₅',
  '6': '₆',
  '7': '₇',
  '8': '₈',
  '9': '₉',
};
const _superscripts = {
  '0': '⁰',
  '1': '¹',
  '2': '²',
  '3': '³',
  '4': '⁴',
  '5': '⁵',
  '6': '⁶',
  '7': '⁷',
  '8': '⁸',
  '9': '⁹',
  '-': '⁻',
};

// Binding strength used to decide where display parentheses are needed.
const _sumLevel = 1, _productLevel = 2, _unaryLevel = 3, _powerLevel = 4, _atomLevel = 5;

sealed class _Node {
  const _Node();

  /// [branch] is 1 for the upper and -1 for the lower branch of a `±`.
  double evaluate(double x, double branch);
  bool get usesX;
  bool get periodic => false;
  int get level;
  String tex();
  String text();

  String texAt(int minimum) => level < minimum
      ? r'\left('
            '${tex()}'
            r'\right)'
      : tex();
  String textAt(int minimum) => level < minimum ? '(${text()})' : text();
}

class _Constant extends _Node {
  const _Constant(this.value, this.literal);
  final double value;
  final String literal;

  @override
  double evaluate(double x, double branch) => value;
  @override
  bool get usesX => false;
  // 1e3 prints as 1×10³, which is a product rather than a single symbol.
  @override
  int get level => RegExp(r'\de').hasMatch(literal) ? _productLevel : _atomLevel;

  @override
  String tex() => switch (literal) {
    'pi' => r'\pi',
    'e' => 'e',
    _ => _scientific(literal, (mantissa, exponent) => '$mantissa\\times10^{$exponent}'),
  };

  @override
  String text() => switch (literal) {
    'pi' => 'π',
    'e' => 'e',
    _ => _scientific(literal, (mantissa, exponent) => '$mantissa×10${_superscript(exponent)}'),
  };

  static String _scientific(String literal, String Function(String mantissa, String exponent) format) {
    final match = RegExp(r'^([\d.]+)e([+-]?\d+)$').firstMatch(literal);
    if (match == null) return literal;
    return format(match[1]!, int.parse(match[2]!).toString());
  }
}

class _Variable extends _Node {
  const _Variable();

  @override
  double evaluate(double x, double branch) => x;
  @override
  bool get usesX => true;
  @override
  int get level => _atomLevel;
  @override
  String tex() => 'x';
  @override
  String text() => 'x';
}

class _Unary extends _Node {
  const _Unary(this.operand, this.negate);
  final _Node operand;
  final bool negate;

  @override
  double evaluate(double x, double branch) => negate ? -operand.evaluate(x, branch) : operand.evaluate(x, branch);
  @override
  bool get usesX => operand.usesX;
  @override
  bool get periodic => operand.periodic;
  @override
  int get level => negate ? _unaryLevel : operand.level;
  @override
  String tex() => negate ? '-${operand.texAt(_unaryLevel)}' : operand.tex();
  @override
  String text() => negate ? '−${operand.textAt(_unaryLevel)}' : operand.text();
}

/// ±a: the upper branch takes +a, the lower −a.
class _PlusMinus extends _Node {
  const _PlusMinus(this.operand);
  final _Node operand;

  @override
  double evaluate(double x, double branch) => branch * operand.evaluate(x, branch);
  @override
  bool get usesX => operand.usesX;
  @override
  bool get periodic => operand.periodic;
  @override
  int get level => _unaryLevel;
  @override
  String tex() => '\\pm ${operand.texAt(_unaryLevel)}';
  @override
  String text() => '±${operand.textAt(_unaryLevel)}';
}

bool _isNegative(_Node node) =>
    (node is _Unary && node.negate) ||
    node is _PlusMinus ||
    (node is _Unary && _isNegative(node.operand)) ||
    _leadsNegative(node);

// -2x parses as (-2)·x and -1/2 as (-1)/2, printed −1/2: both start with a
// minus sign. (-2x)/3 keeps its sign inside the fraction instead.
bool _leadsNegative(_Node node) => switch (node) {
  _Binary(:final operator, :final left) when operator == '*' || operator == '%' => _isNegative(left),
  _Binary(operator: '/', :final left) => left is _Unary && left.negate,
  _ => false,
};

// sin x, ln 2 or sin²x written without parentheses: a factor right after it
// would read as part of its argument (sin x x looks like sin(x²)).
bool _endsWithBareFunction(_Node node) => switch (node) {
  final _Function function => function.named && function._simpleArgument,
  _Binary(operator: '^', :final left, :final right) =>
    left is _Function && left.named && left._simpleArgument && right is _Constant,
  _Binary(:final operator, :final right) when operator == '*' || operator == '%' => _endsWithBareFunction(right),
  _Unary(:final operand) => _endsWithBareFunction(operand),
  _ => false,
};

class _Binary extends _Node {
  const _Binary(this.left, this.operator, this.right);
  final _Node left;
  final String operator;
  final _Node right;

  @override
  double evaluate(double x, double branch) {
    final a = left.evaluate(x, branch);
    final b = right.evaluate(x, branch);
    return switch (operator) {
      '+' => a + b,
      '-' => a - b,
      '±' => a + branch * b,
      '*' => a * b,
      '/' => a / b,
      '%' => a % b,
      '^' => math.pow(a, b).toDouble(),
      _ => double.nan,
    };
  }

  @override
  bool get usesX => left.usesX || right.usesX;

  @override
  bool get periodic => left.periodic || right.periodic;

  @override
  int get level => switch (operator) {
    '+' || '-' || '±' => _sumLevel,
    '*' || '%' => _productLevel,
    '/' => _atomLevel,
    _ => _powerLevel,
  };

  // a + (−b) and a − (b + c) keep their parentheses.
  String _texRight(int minimum) => _isNegative(right)
      ? r'\left('
            '${right.tex()}'
            r'\right)'
      : right.texAt(minimum);
  String _textRight(int minimum) => _isNegative(right) ? '(${right.text()})' : right.textAt(minimum);

  @override
  String tex() {
    switch (operator) {
      case '+':
        return '${left.texAt(_sumLevel)}+${_texRight(_sumLevel)}';
      case '-':
        return '${left.texAt(_sumLevel)}-${_texRight(_productLevel)}';
      case '±':
        return '${left.texAt(_sumLevel)}\\pm ${_texRight(_productLevel)}';
      case '/':
        // -pi/2 parses as (-pi)/2 but reads as −π/2.
        final numerator = left;
        if (numerator is _Unary && numerator.negate) return '-\\frac{${numerator.operand.tex()}}{${right.tex()}}';
        return '\\frac{${left.tex()}}{${right.tex()}}';
      case '%':
        return '${left.texAt(_unaryLevel)}\\bmod ${_texRight(_unaryLevel)}';
      case '^':
        return _powerTex();
    }
    final a = left.texAt(_productLevel);
    final b = _texRight(_unaryLevel);
    // 2x, 3\sin x and (x+1)(x-1) read as products. A dot is needed before a
    // digit, between a number and a fraction (2·½, not the mixed number 2½)
    // and after sin x, whose argument would otherwise seem to continue.
    final dot =
        RegExp(r'^[\d.]').hasMatch(b) ||
        (RegExp(r'\d$').hasMatch(a) && b.startsWith(r'\frac')) ||
        _endsWithBareFunction(left);
    // The space keeps \pi x from turning into the unknown command \pix.
    return dot ? '$a\\cdot $b' : '$a $b';
  }

  String _powerTex() {
    final exponent = right.tex();
    final base = left;
    if (base is _Function && base.named && right is _Constant && RegExp(r'^\d+$').hasMatch(exponent)) {
      return base.tex(power: exponent);
    }
    final needsParentheses = base.level < _atomLevel || (base is _Binary && base.operator == '/') || base is _Function;
    final baseTex = needsParentheses && !(base is _Function && base.delimited)
        ? r'\left('
              '${base.tex()}'
              r'\right)'
        : base.tex();
    return '$baseTex^{$exponent}';
  }

  @override
  String text() {
    switch (operator) {
      case '+':
        return '${left.textAt(_sumLevel)} + ${_textRight(_sumLevel)}';
      case '-':
        return '${left.textAt(_sumLevel)} − ${_textRight(_productLevel)}';
      case '±':
        return '${left.textAt(_sumLevel)} ± ${_textRight(_productLevel)}';
      case '/':
        final numerator = left;
        if (numerator is _Unary && numerator.negate) {
          return '−${_fractionPart(numerator.operand)}/${_fractionPart(right)}';
        }
        return '${_fractionPart(left)}/${_fractionPart(right)}';
      case '%':
        return '${left.textAt(_unaryLevel)} mod ${_textRight(_unaryLevel)}';
      case '^':
        final exponent = right.text();
        final superscript = RegExp(r'^−?\d+$').hasMatch(exponent)
            ? _superscript(exponent.replaceAll('−', '-'))
            : exponent == 'x'
            ? 'ˣ'
            : null;
        final base = left;
        if (superscript != null && base is _Function && base.named && right is _Constant) {
          return base.text(power: superscript);
        }
        final baseText = switch (base) {
          _Function(:final delimited) when delimited => base.text(),
          _Function() || _Binary() => '(${base.text()})',
          _ => base.textAt(_atomLevel),
        };
        if (superscript != null) return '$baseText$superscript';
        return right is _Variable || right is _Constant ? '$baseText^$exponent' : '$baseText^($exponent)';
    }
    // In plain text 1/2·x must not read as 1/(2x), nor 4·1/3 as 4/3.
    final factor = left;
    final a = factor is _Binary && factor.operator == '/' ? '(${factor.text()})' : factor.textAt(_productLevel);
    final next = right;
    final b = next is _Binary && next.operator == '/' && !_isNegative(next)
        ? '(${next.text()})'
        : _textRight(_unaryLevel);
    if (RegExp(r'^[\d.]').hasMatch(b) || _endsWithBareFunction(left)) return '$a·$b';
    // sin x cos x and x sin x need a space where two words would touch.
    return RegExp(r'[A-Za-z]$').hasMatch(a) && RegExp(r'^[A-Za-z]').hasMatch(b) ? '$a $b' : '$a$b';
  }

  static String _fractionPart(_Node node) =>
      node.level >= _atomLevel && !(node is _Binary && node.operator == '/') ? node.text() : '(${node.text()})';
}

String _superscript(String digits) => digits.split('').map((c) => _superscripts[c] ?? c).join();

/// `-12` → `⁻¹²`, for exponents written in plain text.
String plotSuperscript(String digits) => _superscript(digits);

class _Function extends _Node {
  const _Function(this.functionName, this.function, this.argument);
  final String functionName;
  final double Function(double) function;
  final _Node argument;

  static const _texNames = {
    'sin': r'\sin',
    'cos': r'\cos',
    'tan': r'\tan',
    'asin': r'\arcsin',
    'acos': r'\arccos',
    'atan': r'\arctan',
    'ln': r'\ln',
    'log': r'\log_{10}',
    'log10': r'\log_{10}',
    'log2': r'\log_{2}',
    'lg': r'\lg',
  };
  static const _textNames = {
    'sin': 'sin',
    'cos': 'cos',
    'tan': 'tan',
    'asin': 'arcsin',
    'acos': 'arccos',
    'atan': 'arctan',
    'ln': 'ln',
    'log': 'log₁₀',
    'log10': 'log₁₀',
    'log2': 'log₂',
    'lg': 'lg',
  };

  /// Written as an operator name, such as sin x or ln x.
  bool get named => _texNames.containsKey(functionName);

  /// Bracketed by its own symbols (|x|, ⌊x⌋), so a power needs no parentheses.
  bool get delimited => functionName == 'abs' || functionName == 'floor' || functionName == 'ceil';

  @override
  double evaluate(double x, double branch) => function(argument.evaluate(x, branch));
  @override
  bool get usesX => argument.usesX;
  @override
  bool get periodic =>
      ((functionName == 'sin' || functionName == 'cos' || functionName == 'tan') && argument.usesX) ||
      argument.periodic;
  @override
  int get level => functionName == 'exp' ? _powerLevel : _atomLevel;

  // sin x and ln 2 need no parentheses; anything longer keeps them.
  bool get _simpleArgument => argument is _Variable || argument is _Constant;

  @override
  String tex({String? power}) {
    final inner = argument.tex();
    switch (functionName) {
      case 'sqrt':
        return '\\sqrt{$inner}';
      case 'cbrt':
        return '\\sqrt[3]{$inner}';
      case 'abs':
        return r'\left|'
            '$inner'
            r'\right|';
      case 'floor':
        return r'\left\lfloor '
            '$inner'
            r'\right\rfloor';
      case 'ceil':
        return r'\left\lceil '
            '$inner'
            r'\right\rceil';
      case 'exp':
        return 'e^{$inner}';
    }
    final name = '${_texNames[functionName]}${power == null ? '' : '^{$power}'}';
    if (_simpleArgument) return '$name $inner';
    return inner.contains(r'\frac') ? '$name\\left($inner\\right)' : '$name($inner)';
  }

  /// [power] is an already superscripted exponent, as in sin²x.
  @override
  String text({String? power}) {
    final inner = argument.text();
    switch (functionName) {
      case 'sqrt':
        return _simpleArgument ? '√$inner' : '√($inner)';
      case 'cbrt':
        return _simpleArgument ? '∛$inner' : '∛($inner)';
      case 'abs':
        return '|$inner|';
      case 'floor':
        return '⌊$inner⌋';
      case 'ceil':
        return '⌈$inner⌉';
      case 'exp':
        return inner == 'x' ? 'eˣ' : 'e^($inner)';
    }
    final name = '${_textNames[functionName]}${power ?? ''}';
    return _simpleArgument ? '$name $inner' : '$name($inner)';
  }
}

class _Parser {
  _Parser(this.source);
  final String source;
  int _index = 0;
  int _depth = 0;
  int _nodes = 0;

  /// How many `±` the expression used; more than one is rejected.
  int plusMinus = 0;

  static final _number = RegExp(r'(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?');
  // Digits may end a name, as in log2 and log10.
  static final _identifier = RegExp(r'[a-z]+\d*');
  static final _functions = <String, double Function(double)>{
    'sin': math.sin,
    'cos': math.cos,
    'tan': math.tan,
    'asin': math.asin,
    'acos': math.acos,
    'atan': math.atan,
    'sqrt': math.sqrt,
    // x^(1/3) is NaN for negative x; the real cube root is defined everywhere.
    'cbrt': (value) => value < 0 ? -math.pow(-value, 1 / 3).toDouble() : math.pow(value, 1 / 3).toDouble(),
    'ln': math.log,
    'log': (value) => math.log(value) / math.ln10,
    'log10': (value) => math.log(value) / math.ln10,
    'lg': (value) => math.log(value) / math.ln10,
    'log2': (value) => math.log(value) / math.ln2,
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
    while (_peek == '+' || _peek == '-' || _peek == '±') {
      final operator = _peek;
      _index++;
      if (operator == '±') _countPlusMinus();
      result = _node(_Binary(result, operator, _product()));
    }
    return result;
  }

  void _countPlusMinus() {
    if (++plusMinus > 1) {
      throw const FormatException('Use ± at most once in a function; give further branches as separate functions.');
    }
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
    if (_take('±')) {
      _countPlusMinus();
      return _node(_PlusMinus(_nested(_unary)));
    }
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
      final literal = number.group(0)!;
      final value = double.parse(literal);
      if (!value.isFinite) throw const FormatException('Numeric constants must be finite.');
      return _node(_Constant(value, literal));
    }
    final identifier = _identifier.matchAsPrefix(source, _index);
    if (identifier != null) {
      _index = identifier.end;
      final name = identifier.group(0)!;
      if (name == 'x') return _node(const _Variable());
      if (name == 'pi') return _node(const _Constant(math.pi, 'pi'));
      if (name == 'e') return _node(const _Constant(math.e, 'e'));
      final function = _functions[name];
      if (function == null) throw FormatException('Unknown function or variable "$name".');
      if (!_take('(')) throw FormatException('Expected ( after $name.');
      final argument = _nested(_sum);
      if (!_take(')')) throw const FormatException('Missing closing parenthesis.');
      return _node(_Function(name, function, argument));
    }
    throw FormatException('Unexpected "$_peek" at position ${_index + 1}.');
  }
}
