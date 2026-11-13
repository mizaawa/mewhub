import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_math_fork/tex.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/tools/cartesian_plot.dart';
import 'package:mewhub/tools/local_tools.dart';
import 'package:mewhub/tools/plot_expression.dart';

void main() {
  group('PlotExpression', () {
    test('evaluates precedence, signed exponents, and right-associative powers', () {
      expect(PlotExpression.compile('-x^2').evaluate(3), -9);
      expect(PlotExpression.compile('x^-2').evaluate(2), 0.25);
      expect(PlotExpression.compile('2^3^2').evaluate(1), 512);
      expect(PlotExpression.compile('2( x + 1 )').evaluate(3), 8);
    });

    test('evaluates supported functions, constants, and common graph syntax', () {
      expect(PlotExpression.compile('y = sin(pi / 2)').evaluate(0), closeTo(1, 1e-10));
      expect(PlotExpression.compile('sqrt(x)+abs(-3)').evaluate(4), 5);
      expect(PlotExpression.compile('log(100)+ln(e)').evaluate(0), closeTo(3, 1e-10));
      expect(PlotExpression.compile('2x + 1').evaluate(4), 9);
    });

    test('leaves domain gaps as nonfinite values', () {
      expect(PlotExpression.compile('1 / x').evaluate(0).isInfinite, isTrue);
      expect(PlotExpression.compile('sqrt(x)').evaluate(-1).isNaN, isTrue);
    });

    test('rejects code, unknown symbols, broken syntax and resource abuse', () {
      for (final expression in [
        '',
        'import dart:io',
        'alert(x)',
        'x; throw 1',
        '(',
        'sin x',
        '1${List.filled(193, '+1').join()}',
        '(${List.filled(50, '(').join()}x${List.filled(50, ')').join()})',
        List.filled(513, 'x').join(),
      ]) {
        expect(() => PlotExpression.compile(expression), throwsFormatException, reason: expression);
      }
    });
  });

  group('PlotExpression names and lines', () {
    test('reads textbook definitions without changing what is plotted', () {
      final f = PlotExpression.compile('f(x) = x^2');
      expect(f.name, 'f(x)');
      expect(f.evaluate(3), 9);
      expect(PlotExpression.compile('y_1 = 2x + 1').name, 'y_1');
      expect(PlotExpression.compile('y1=2x+1').name, 'y_1');
      expect(PlotExpression.compile("g'(x) = 3x^2").name, "g'(x)");
      final line = PlotExpression.compile('l: y = -x + 3');
      expect(line.label, 'l');
      expect(line.name, 'y');
      expect(line.evaluate(1), 2);
      expect(PlotExpression.compile('l_1：y＝2x').label, 'l_1');
      expect(PlotExpression.compile('2x + 1').name, isNull);
    });

    test('x = c is a vertical line and must stay constant', () {
      final axis = PlotExpression.compile('x = 2');
      expect(axis.isVertical, isTrue);
      expect(axis.verticalX, 2);
      expect(axis.evaluate(2).isNaN, isTrue);
      expect(PlotExpression.compile('x = -pi/2').verticalX, closeTo(-math.pi / 2, 1e-12));
      for (final bad in ['x = 2x', 'x = sqrt(-1)', 'x = 1/0']) {
        expect(() => PlotExpression.compile(bad), throwsFormatException, reason: bad);
      }
    });

    test('cbrt is the real cube root on both sides of zero', () {
      expect(PlotExpression.compile('cbrt(x)').evaluate(-8), closeTo(-2, 1e-12));
      expect(PlotExpression.compile('cbrt(x)').evaluate(27), closeTo(3, 1e-12));
      expect(PlotExpression.compile('x^(1/3)').evaluate(-8).isNaN, isTrue);
    });
  });

  group('PlotExpression formulas', () {
    test('typesets the expression the way it is plotted', () {
      final cases = {
        'x^2 - 4x + 3': 'x^{2}-4 x+3',
        '1/x': r'\frac{1}{x}',
        'sqrt(x)': r'\sqrt{x}',
        'cbrt(x - 1)': r'\sqrt[3]{x-1}',
        'sin(x)': r'\sin x',
        'sin(x)^2': r'\sin^{2} x',
        'ln(x + 1)': r'\ln(x+1)',
        'log(x)': r'\log_{10} x',
        'abs(x - 2)': r'\left|x-2\right|',
        'e^x': 'e^{x}',
        'exp(-x^2/2)': r'e^{-\frac{x^{2}}{2}}',
        '-pi/2': r'-\frac{\pi}{2}',
        'pi*x': r'\pi x',
        'x*2': r'x\cdot 2',
        '(x+1)(x-1)': r'\left(x+1\right) \left(x-1\right)',
        'x - (-1)': r'x-\left(-1\right)',
        '-x^2+4': '-x^{2}+4',
        '(1/2)^x': r'\left(\frac{1}{2}\right)^{x}',
        // A negative fraction as a factor is not a subtraction (x − ½).
        'x*(-1/2)': r'x \left(-\frac{1}{2}\right)',
        '2*(-1/2)*x': r'2 \left(-\frac{1}{2}\right) x',
        // A number times a fraction is not the mixed number 4⅓.
        '4(1/3)x': r'4\cdot \frac{1}{3} x',
        // sin x x would read as sin(x²).
        'sin(x)*x': r'\sin x\cdot x',
        'ln(x)*x': r'\ln x\cdot x',
        '3sin(x)cos(x)': r'3 \sin x\cdot \cos x',
      };
      cases.forEach((source, tex) => expect(PlotExpression.compile(source).tex, tex, reason: source));
    });

    test('every construct produces TeX the chat renderer accepts', () {
      for (final source in [
        'x^2 - 4x + 3',
        '2^3^2',
        '(2^3)^2',
        'x^-2',
        'x^(1/3)',
        'e^(x+1)',
        '3sin(x)cos(x)',
        'x(x+1)',
        '0.5x^2',
        '1e3*x',
        'x%3',
        'floor(x)',
        'ceil(x/2)',
        'abs(x)^2',
        'sqrt(x)^2',
        'asin(x)',
        'acos(x)',
        'atan(x)',
        'tan(x)',
        'exp(x)',
        'cbrt(x)',
        'sqrt(9 - x^2)',
        '-sqrt(9-x^2)',
        'x + -2x',
        '-(x+1)',
        '1/2x',
        '(x^3-3x+1)/(x^2+1)',
      ]) {
        final tex = PlotExpression.compile(source).tex;
        expect(() => TexParser(tex, const TexParserSettings()).parse(), returnsNormally, reason: '$source → $tex');
      }
    });

    test('writes readable plain text for canvases and screen readers', () {
      final cases = {
        'x^2 - 4x + 3': 'x² − 4x + 3',
        '-pi/2': '−π/2',
        'x^(1/3)': 'x^(1/3)',
        '1/2x': '(1/2)x',
        'sin(x)^2': 'sin² x',
        '3sin(x)cos(x)': '3sin x·cos x',
        'e^x': 'eˣ',
        'x^-1': 'x⁻¹',
        'sqrt(9 - x^2)': '√(9 − x²)',
        'log(x)': 'log₁₀ x',
        'x*(-1/2)': 'x(−1/2)',
        '4(1/3)x': '4(1/3)x',
        'sin(x)*x': 'sin x·x',
      };
      cases.forEach((source, text) => expect(PlotExpression.compile(source).text, text, reason: source));
    });
  });

  group('Exact coordinates', () {
    test('prints values the way a solution writes them', () {
      final cases = <double, String>{
        0: '0',
        3: '3',
        -1.5: '−1.5',
        0.25: '0.25',
        1 / 3: '1/3',
        -4 / 3: '−4/3',
        0.125: '0.125',
        0.333333: '1/3',
        math.pi / 2: 'π/2',
        -3 * math.pi / 4: '−3π/4',
        2 * math.pi: '2π',
        1.5707963268: 'π/2',
        math.sqrt(2) / 2: '√2/2',
        0.866025: '√3/2',
        2 * math.sqrt(3): '2√3',
        1.4142: '1.4142',
        0.4321: '0.4321',
        0.00012: '1.2×10⁻⁴',
        // Near-integers are integers, not 4/2; noise is 0, not −0.
        2.0000001064249604: '2',
        0.9999999: '1',
        -0.9999999: '−1',
        -1.8369701987210297e-16: '0',
        -1e-12: '0',
        // Data written with up to four decimals stays as written.
        1000.0004: '1000.0004',
        1157.625: '1157.625',
        26251.578: '26251.578',
        0.6227: '0.6227',
        5.755: '5.755',
        84.823: '84.823',
      };
      cases.forEach((value, text) => expect(formatPlotNumber(value), text, reason: '$value'));
    });

    test('point labels lose a repeated coordinate pair but keep symbolic names', () {
      final cases = {
        'A(1, 2)': 'A',
        'A (1,2)': 'A',
        '顶点 (2, -1)': '顶点',
        'B：（3，0）': 'B',
        'C = (−1.5, 0)': 'C',
        'M(π/4, √2/2)': 'M',
        'N(pi/2, 1)': 'N',
        '(1, 2)': '',
        'P(t, t²)': 'P(t, t²)',
        'f(2)': 'f(2)',
        'P_1': 'P₁',
        'O': 'O',
        'A(pi, 0)': 'A',
        'C(-pi, 0)': 'C',
        'F(2sqrt(3), 0)': 'F',
        'G(sqrt(3)/2, 0)': 'G',
        'B(e, 1)': 'B',
        'H(ln 2, 0)': 'H',
        'K(ln(2), 0)': 'K',
        '零点∈(1, 2)': '零点∈(1, 2)',
        'Q(sqrt(x), 1)': 'Q(sqrt(x), 1)',
        r'$P_1$': 'P₁',
        'A_{1}': 'A₁',
      };
      cases.forEach((label, name) => expect(plotPointName(label), name, reason: label));
    });

    test('a point prints its name and coordinates once, or hides them on request', () {
      expect(const PlotPoint(x: 1, y: 0, label: 'A(1, 0)').caption, 'A (1, 0)');
      expect(const PlotPoint(x: 1 / 3, y: -4 / 3).caption, '(1/3, −4/3)');
      final hidden = PlotPoint.fromJson({'x': 2, 'y': -1, 'label': 'P', 'show_coordinates': false});
      expect(hidden.caption, 'P');
      final restored = PlotPoint.fromJson(jsonDecode(jsonEncode(hidden.toJson())) as Map<String, dynamic>);
      expect(restored.showCoordinates, isFalse);
      expect(PlotPoint.fromJson({'x': 1, 'y': 1}).showCoordinates, isTrue);
    });
  });

  group('Curve names', () {
    test('a single unnamed curve needs no tag; several are numbered', () {
      final single = CartesianPlot(functions: const ['x^2']).curves.single;
      expect(single.tag, isNull);
      expect(single.equationTex, 'y=x^{2}');
      expect(single.equationText, 'y = x²');
      final both = CartesianPlot(functions: const ['x^2', 'y = 2x + 1']).curves;
      expect(both.map((c) => c.tag), ['y₁', 'y₂']);
      expect(both.last.equationTex, 'y_{2}=2 x+1');
    });

    test('given names, labels and vertical lines are kept and never collide', () {
      final curves = CartesianPlot(
        functions: const ['f(x) = x^2 - 2x - 3', 'y_1 = x', 'x + 1', '-x', 'l: y = 3', 'x = 1'],
      ).curves;
      expect(curves.map((c) => c.tag), ['f(x)', 'y₁', 'y₂', 'y₃', 'l', 'x = 1']);
      expect(curves.first.equationText, 'f(x) = x² − 2x − 3');
      expect(curves[4].equationText, 'l: y = 3');
      expect(curves.last.equationTex, 'x=1');
      for (final curve in curves) {
        expect(() => TexParser(curve.equationTex, const TexParserSettings()).parse(), returnsNormally);
      }
    });
  });

  group('Conics, logarithms and reference lines', () {
    test('one ± draws both branches of a circle', () {
      final circle = PlotExpression.compile('C: y = ±sqrt(9 - x^2)');
      expect(circle.label, 'C');
      expect(circle.plusMinus, isTrue);
      expect(circle.evaluate(0), 3);
      expect(circle.evaluate(0, lower: true), -3);
      expect(circle.tex, r'\pm \sqrt{9-x^{2}}');
      expect(circle.text, '±√(9 − x²)');
      final shifted = PlotExpression.compile(r'y = 1 \pm sqrt(4 - (x - 2)^2)');
      expect(shifted.evaluate(2), 3);
      expect(shifted.evaluate(2, lower: true), -1);
      expect(shifted.tex, r'1\pm \sqrt{4-\left(x-2\right)^{2}}');
      expect(PlotExpression.compile('x^2').plusMinus, isFalse);
      expect(() => PlotExpression.compile('±x ± 1'), throwsFormatException);
      expect(() => PlotExpression.compile('x = ±2'), throwsFormatException);
    });

    test('log2 and lg read like the textbook', () {
      expect(PlotExpression.compile('log2(x)').evaluate(8), closeTo(3, 1e-12));
      expect(PlotExpression.compile('lg(x)').evaluate(100), closeTo(2, 1e-12));
      expect(PlotExpression.compile('log10(x)').evaluate(1000), closeTo(3, 1e-12));
      expect(PlotExpression.compile('log2(x)').tex, r'\log_{2} x');
      expect(PlotExpression.compile('lg(x + 1)').text, 'lg(x + 1)');
      expect(PlotExpression.compile('AB: y = -x + 4').label, 'AB');
    });

    test('periodic curves are recognised for π ticks', () {
      expect(PlotExpression.compile('sin(x)').isPeriodic, isTrue);
      expect(PlotExpression.compile('2cos(3x) + 1').isPeriodic, isTrue);
      expect(PlotExpression.compile('sin(2)').isPeriodic, isFalse);
      expect(PlotExpression.compile('x^2').isPeriodic, isFalse);
    });

    test('an unnamed constant is a dashed horizontal line; a named one is a curve', () {
      final curves = CartesianPlot(functions: const ['2/(x - 1) + 1', 'x = 1', 'y = 1', 'g(x) = 3']).curves;
      expect(curves.map((c) => c.tag), [null, 'x = 1', 'y = 1', 'g(x)']);
      expect(curves.map((c) => c.dashed), [false, true, true, false]);
      expect(curves.first.equationText, 'y = 2/(x − 1) + 1');
    });

    test('primes in names are typeset as primes', () {
      expect(plotPointName("A'"), 'A′');
      expect(plotNameText("g'(x)"), 'g′(x)');
    });
  });

  group('Segments', () {
    test('join named points and survive a round trip', () {
      final plot = CartesianPlot.fromJson({
        'points': [
          {'x': 0, 'y': 0, 'label': 'A'},
          {'x': 4, 'y': 0, 'label': 'B'},
          {'x': 1, 'y': 3, 'label': 'P_1'},
        ],
        'segments': [
          {'from': 'A', 'to': 'B'},
          {'from': 'B', 'to': 'P_1'},
          {'from': 'P_1', 'to': 'A', 'dashed': true},
        ],
      });
      expect(plot.segments, hasLength(3));
      expect(plot.pointNamed('P_1').y, 3);
      final restored = CartesianPlot.fromJson(jsonDecode(jsonEncode(plot.toJson())) as Map<String, dynamic>);
      expect(restored.segments.map((s) => s.dashed), [false, false, true]);
      expect(CartesianPlot(functions: const ['x']).toJson().containsKey('segments'), isFalse);
    });

    test('reject missing, ambiguous or identical ends', () {
      const points = [
        {'x': 0, 'y': 0, 'label': 'A'},
        {'x': 1, 'y': 1, 'label': 'A'},
        {'x': 2, 'y': 0, 'label': 'B'},
      ];
      for (final segment in [
        {'from': 'B', 'to': 'C'},
        {'from': 'A', 'to': 'B'},
        {'from': 'B', 'to': 'B'},
        {'from': 'B'},
      ]) {
        expect(
          () => CartesianPlot.fromJson({
            'points': points,
            'segments': [segment],
          }),
          throwsFormatException,
          reason: '$segment',
        );
      }
      expect(
        () => CartesianPlot.fromJson({
          'points': points.sublist(1),
          'segments': List.filled(33, {'from': 'A', 'to': 'B'}),
        }),
        throwsFormatException,
      );
    });

    test('the tool accepts a triangle whose labels came with coordinates', () async {
      final result = jsonDecode(
        await buildCartesianPlotTool().execute({
          'points': [
            {'x': 0, 'y': 0, 'label': 'A(0, 0)'},
            {'x': 4, 'y': 0, 'label': 'B'},
            {'x': 1, 'y': 3, 'label': 'C'},
          ],
          'segments': [
            {'from': 'A', 'to': 'B'},
            {'from': 'B', 'to': 'C'},
            {'from': 'C', 'to': 'A'},
          ],
          'x_min': -1,
          'x_max': 5,
          'y_min': -1,
          'y_max': 4,
        }),
      ) as Map<String, dynamic>;
      expect(result['type'], 'cartesian_plot');
      expect(CartesianPlot.fromJson(result['plot'] as Map<String, dynamic>).segments, hasLength(3));
    });
  });

  group('CartesianPlot', () {
    test('serializes and restores bounded graph data', () {
      final plot = CartesianPlot(
        title: 'Parabola',
        xMin: -5,
        xMax: 5,
        yMin: -2,
        yMax: 20,
        functions: const ['x^2'],
        points: const [PlotPoint(x: 2, y: 4, label: 'A')],
      );
      final json = jsonDecode(jsonEncode(plot.toJson())) as Map<String, dynamic>;
      final restored = CartesianPlot.fromJson(json);
      expect(restored.title, 'Parabola');
      expect(restored.functions, ['x^2']);
      expect(restored.xMin, -5);
      expect(restored.points.single.x, 2);
      expect(restored.points.single.label, 'A');
    });

    test('provides a valid factory demo and immutable contents', () {
      final plot = CartesianPlot.example();
      expect(plot.functions, ['x^2', '2x + 1']);
      expect(() => plot.functions.add('x'), throwsUnsupportedError);
      expect(() => plot.points.add(const PlotPoint(x: 1, y: 1)), throwsUnsupportedError);
    });

    test('rejects nonfinite bounds, inverted or tiny ranges, oversized inputs, and unsafe points', () {
      for (final json in <Map<String, dynamic>>[
        {'x_min': double.nan},
        {'y_max': double.infinity},
        {'x_min': 11, 'x_max': 10},
        {'y_min': 1, 'y_max': 1},
        {'x_min': -1000001},
        {
          'points': [null],
        },
        {
          'functions': ['x;'],
        },
        {
          'points': List.filled(65, {'x': 1, 'y': 1}),
        },
        {'functions': List.filled(9, 'x')},
        {
          'points': [
            {'x': double.nan, 'y': 0},
          ],
        },
      ]) {
        expect(() => CartesianPlot.fromJson(json), throwsFormatException, reason: '$json');
      }
    });
  });

  group('Cartesian plotting tool', () {
    test('returns renderable structured chat output for a model-created plot', () async {
      final tool = buildCartesianPlotTool();
      expect(tool.name, 'plot_cartesian');
      final result = jsonDecode(
        await tool.execute({
          'title': 'Vertex',
          'functions': ['x^2'],
          'points': [
            {'x': 1, 'y': 1, 'label': 'A'},
          ],
        }),
      ) as Map<String, dynamic>;
      expect(result['type'], 'cartesian_plot');
      expect(CartesianPlot.fromJson(result['plot'] as Map<String, dynamic>).points.single.label, 'A');
    });

    test('cleans coordinates out of labels and tells the model why', () async {
      final result = jsonDecode(
        await buildCartesianPlotTool().execute({
          'functions': ['x^2 - 4x + 3'],
          'points': [
            {'x': 1, 'y': 0, 'label': 'A(1, 0)'},
            {'x': 2, 'y': -1, 'label': '顶点'},
          ],
          'x_min': -1,
          'x_max': 5,
          'y_min': -2,
          'y_max': 6,
        }),
      ) as Map<String, dynamic>;
      final plot = CartesianPlot.fromJson(result['plot'] as Map<String, dynamic>);
      expect(plot.points.map((p) => p.label), ['A', '顶点']);
      expect(plot.points.first.caption, 'A (1, 0)');
      expect(result['status'], contains('shown'));
      expect((result['notes'] as List).single, contains('"A(1, 0)"'));
    });

    test('warns about parts of the figure that fall outside the window', () async {
      final result = jsonDecode(
        await buildCartesianPlotTool().execute({
          'functions': ['x^2 + 50', 'sqrt(x - 100)', 'x = 30', 'x'],
          'points': [
            {'x': 40, 'y': 0, 'label': 'C'},
          ],
        }),
      ) as Map<String, dynamic>;
      final notes = (result['notes'] as List).cast<String>();
      expect(notes, hasLength(4));
      expect(
        notes.join('\n'),
        allOf(contains('y₁ = x² + 50'), contains('undefined'), contains('x = 30'), contains('C (40, 0)')),
      );
      expect(result['type'], 'cartesian_plot');
    });

    test('a well-chosen window needs no notes', () async {
      final result = jsonDecode(
        await buildCartesianPlotTool().execute({
          'functions': ['f(x) = x^2'],
          'points': [
            {'x': 0, 'y': 0, 'label': 'O'},
          ],
        }),
      ) as Map<String, dynamic>;
      expect(result.containsKey('notes'), isFalse);
    });

    test('without LaTeX rendering the prompt asks for Unicode math instead', () {
      final tool = buildLocalTools({LocalTool.cartesianPlot}, latex: false).single;
      expect(tool.promptHint, allOf(contains('Unicode'), isNot(contains(r'$...$'))));
      expect(tool.description, allOf(contains('Unicode'), isNot(contains(r'$...$'))));
      expect(tool.description, contains('never by colour'));
    });

    test('refuses "+-" and short exponents that would plot another curve', () async {
      for (final function in ['1 +- sqrt(4 - x^2)', 'x +/- 1', 'e^2x', 'e^-0.5x', '10^3(x)']) {
        final result = jsonDecode(
          await buildCartesianPlotTool().execute({
            'functions': [function],
          }),
        ) as Map<String, dynamic>;
        expect(result.containsKey('error'), isTrue, reason: function);
      }
      for (final function in ['x + -2x', 'e^(2x)', 'x^2 (x + 1)', 'x^2 - 4x', '±sqrt(4 - x^2)']) {
        final result = jsonDecode(
          await buildCartesianPlotTool().execute({
            'functions': [function],
          }),
        ) as Map<String, dynamic>;
        expect(result['type'], 'cartesian_plot', reason: function);
      }
    });

    test('equal plots compare equal, so an unchanged graph is not repainted', () {
      final json = CartesianPlot.example().toJson();
      final a = CartesianPlot.fromJson(json);
      final b = CartesianPlot.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.copyWith(xMax: 11)));
    });

    test('the prompt asks for names-only labels and LaTeX replies', () {
      final tool = buildLocalTools({LocalTool.cartesianPlot}).single;
      final schema = jsonEncode(tool.parameters);
      expect(tool.description, allOf(contains('name only'), contains('never write coordinates into a label')));
      expect(tool.description, contains(r'$...$'));
      expect(
        schema,
        allOf(contains('show_coordinates'), contains('x = 2'), contains('f(x) = x^2'), contains('segments')),
      );
      expect(tool.description, contains('±sqrt(9 - x^2)'));
      expect(tool.promptHint, allOf(contains('<math_graphs>'), contains('LaTeX')));
    });

    test('returns a safe visible validation error for invalid model arguments', () async {
      final result = jsonDecode(
        await buildCartesianPlotTool().execute({
          'functions': ['evil()'],
        }),
      ) as Map<String, dynamic>;
      expect(result.containsKey('error'), isTrue);
      expect(result.containsKey('type'), isFalse);
    });
  });
}
