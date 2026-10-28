/// Works out arithmetic for the calculator tool: + - * / ^ %, brackets,
/// and sqrt, sin, cos, tan, asin, acos, atan, ln, log, log2, exp, abs,
/// round, floor, ceil, min, max, with pi and e. Angles are in radians.
library;

import 'dart:math' as math;

class CalcException implements Exception {
  CalcException(this.message);
  final String message;
  @override
  String toString() => message;
}

num calculate(String expression) => _Parser(expression).parse();

/// A result as people write it: whole numbers without ".0", others to 12
/// significant digits.
String formatNumber(num n) {
  if (n.isNaN) return 'not a number';
  if (n.isInfinite) return n > 0 ? 'infinity' : '-infinity';
  if (n == n.roundToDouble() && n.abs() < 1e15) return '${n.round()}';
  final s = n.toStringAsPrecision(12);
  if (s.contains('e')) return s;
  return s.contains('.')
      ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : s;
}

final _functions = <String, num Function(List<num>)>{
  'sqrt': _one(math.sqrt),
  'sin': _one(math.sin),
  'cos': _one(math.cos),
  'tan': _one(math.tan),
  'asin': _one(math.asin),
  'acos': _one(math.acos),
  'atan': _one(math.atan),
  'ln': _one(math.log),
  'exp': _one(math.exp),
  'log': _log10,
  'log10': _log10,
  'log2': _log2,
  'abs': _abs,
  'round': _round,
  'floor': _floor,
  'ceil': _ceil,
  'min': _min,
  'max': _max,
};

num Function(List<num>) _one(num Function(num) f) =>
    (a) => f(_only(a));
num _only(List<num> a) {
  if (a.length != 1) throw CalcException('Expected one number');
  return a.single;
}

num _log10(List<num> a) => math.log(_only(a)) / math.ln10;
num _log2(List<num> a) => math.log(_only(a)) / math.ln2;
num _abs(List<num> a) => _only(a).abs();
num _round(List<num> a) => _only(a).round();
num _floor(List<num> a) => _only(a).floor();
num _ceil(List<num> a) => _only(a).ceil();
num _min(List<num> a) => a.reduce(math.min);
num _max(List<num> a) => a.reduce(math.max);

class _Parser {
  _Parser(String text)
    : _s = text
          .replaceAll('×', '*')
          .replaceAll('÷', '/')
          .replaceAll('−', '-')
          .replaceAll('**', '^')
          .replaceAll(RegExp(r'(?<=\d),(?=\d{3}\b)'), '')
          .toLowerCase();

  final String _s;
  int _i = 0;

  num parse() {
    if (_s.trim().isEmpty) throw CalcException('Nothing to work out');
    final v = _sum();
    _space();
    if (_i < _s.length) {
      throw CalcException("Didn't understand '${_s.substring(_i)}'");
    }
    return v;
  }

  void _space() {
    while (_i < _s.length && _s[_i].trim().isEmpty) {
      _i++;
    }
  }

  bool _eat(String c) {
    _space();
    if (_s.startsWith(c, _i)) {
      _i += c.length;
      return true;
    }
    return false;
  }

  num _sum() {
    var v = _product();
    while (true) {
      if (_eat('+')) {
        v += _product();
      } else if (_eat('-')) {
        v -= _product();
      } else {
        return v;
      }
    }
  }

  num _product() {
    var v = _unary();
    while (true) {
      if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        final d = _unary();
        if (d == 0) throw CalcException('Division by zero');
        v /= d;
      } else if (_eat('mod')) {
        v %= _unary();
      } else {
        return v;
      }
    }
  }

  num _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
  }

  num _power() {
    final base = _postfix();
    if (_eat('^')) return math.pow(base, _unary());
    return base;
  }

  num _postfix() {
    var v = _atom();
    while (true) {
      _space();
      if (_eat('%')) {
        v /= 100;
      } else if (_eat('!')) {
        if (v < 0 || v != v.roundToDouble() || v > 170) {
          throw CalcException('Factorial needs a whole number up to 170');
        }
        // A double: whole numbers overflow past 20!.
        num f = 1.0;
        for (var k = 2; k <= v; k++) {
          f *= k;
        }
        v = f;
      } else {
        return v;
      }
    }
  }

  num _atom() {
    _space();
    if (_eat('(')) {
      final v = _sum();
      if (!_eat(')')) throw CalcException('Missing )');
      return v;
    }
    final number = RegExp(r'\d+(?:\.\d*)?(?:e[+-]?\d+)?|\.\d+')
        .matchAsPrefix(_s, _i);
    if (number != null) {
      _i = number.end;
      return num.parse(number[0]!);
    }
    final word = RegExp(r'[a-z][a-z0-9]*').matchAsPrefix(_s, _i);
    if (word != null) {
      _i = word.end;
      final w = word[0]!;
      if (w == 'pi') return math.pi;
      if (w == 'e') return math.e;
      final f = _functions[w];
      if (f == null) throw CalcException("Unknown name '$w'");
      if (!_eat('(')) return f([_power()]);
      final args = <num>[_sum()];
      while (_eat(',')) {
        args.add(_sum());
      }
      if (!_eat(')')) throw CalcException('Missing )');
      return f(args);
    }
    throw CalcException(
      _i < _s.length ? "Didn't understand '${_s[_i]}'" : 'It ends too soon',
    );
  }
}
