import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:semble_dart/semble_dart.dart';

const _queries = [
  'authenticate token',
  'parse command line arguments',
  'cache invalidation metadata',
  'tree sitter chunk source files',
  'format search results json',
  'find related code location',
];

Future<void> main(List<String> args) async {
  final repo =
      _arg(args, '--repo') ??
      p.normalize(p.absolute(p.join('..', '.research', 'semble')));
  final pythonRepo =
      _arg(args, '--python-repo') ??
      p.normalize(p.absolute(p.join('..', '.research', 'semble')));
  final python =
      _arg(args, '--python') ??
      p.join(pythonRepo, '.bench-venv', 'bin', 'python');
  final modelRoot = _arg(args, '--model') ?? _defaultModelRoot();
  final rounds = int.parse(_arg(args, '--rounds') ?? '5');
  final topK = int.parse(_arg(args, '--top-k') ?? '5');

  if (!Directory(repo).existsSync()) {
    stderr.writeln('Dart repo path does not exist: $repo');
    exit(64);
  }
  if (!File(python).existsSync()) {
    stderr.writeln('Python executable does not exist: $python');
    exit(64);
  }

  final modelPath = p.join(modelRoot, 'model.safetensors');
  final tokenizerPath = p.join(modelRoot, 'tokenizer.json');
  if (!File(modelPath).existsSync() || !File(tokenizerPath).existsSync()) {
    stderr.writeln(
      'Model snapshot missing model.safetensors/tokenizer.json: $modelRoot',
    );
    exit(64);
  }

  print('repo: $repo');
  print('python repo: $pythonRepo');
  print('model: $modelRoot');
  print('queries: ${_queries.length}, rounds: $rounds, topK: $topK');
  print('');

  final dart = await _benchDart(
    repo: repo,
    modelPath: modelPath,
    tokenizerPath: tokenizerPath,
    rounds: rounds,
    topK: topK,
  );
  final pythonResult = await _benchPython(
    python: python,
    pythonRepo: pythonRepo,
    repo: repo,
    modelRoot: modelRoot,
    rounds: rounds,
    topK: topK,
  );

  _printTable(dart, pythonResult);
  print('');
  print(
    jsonEncode({
      'dart': dart.toJson(),
      'python': pythonResult.toJson(),
      'speedup': {
        'build': pythonResult.buildMs / dart.buildMs,
        'warm_search_p50': pythonResult.searchP50Ms / dart.searchP50Ms,
        'warm_search_p95': pythonResult.searchP95Ms / dart.searchP95Ms,
      },
    }),
  );
}

Future<_BenchResult> _benchDart({
  required String repo,
  required String modelPath,
  required String tokenizerPath,
  required int rounds,
  required int topK,
}) async {
  final spawnWatch = Stopwatch()..start();
  final isolate = await SembleSearchIsolate.spawn(
    modelPath: modelPath,
    tokenizerPath: tokenizerPath,
    grammarsLibPath: '',
  );
  final prewarmWatch = Stopwatch()..start();
  await isolate.prewarm(repo, timeout: const Duration(minutes: 5));
  prewarmWatch.stop();
  spawnWatch.stop();

  final timings = <double>[];
  final topPaths = <String, List<String>>{};
  for (var round = 0; round < rounds; round++) {
    for (final query in _queries) {
      final watch = Stopwatch()..start();
      final results = await isolate.search(
        query,
        path: repo,
        topK: topK,
        timeout: const Duration(minutes: 2),
      );
      watch.stop();
      timings.add(watch.elapsedMicroseconds / 1000.0);
      topPaths.putIfAbsent(
        query,
        () => [
          for (final result in results)
            p.isWithin(repo, result.filePath)
                ? p.relative(result.filePath, from: repo)
                : result.filePath,
        ],
      );
    }
  }
  await isolate.shutdown();

  return _BenchResult(
    name: 'dart',
    buildMs: prewarmWatch.elapsedMicroseconds / 1000.0,
    totalSetupMs: spawnWatch.elapsedMicroseconds / 1000.0,
    searchP50Ms: _percentile(timings, 0.50),
    searchP95Ms: _percentile(timings, 0.95),
    searchMeanMs: timings.reduce((a, b) => a + b) / timings.length,
    topPaths: topPaths,
  );
}

Future<_BenchResult> _benchPython({
  required String python,
  required String pythonRepo,
  required String repo,
  required String modelRoot,
  required int rounds,
  required int topK,
}) async {
  final script = File(
    p.join(Directory.systemTemp.path, 'semble_python_bench.py'),
  );
  await script.writeAsString(_pythonBenchSource);

  final process = await Process.run(python, [
    script.path,
    '--repo',
    repo,
    '--model',
    modelRoot,
    '--rounds',
    '$rounds',
    '--top-k',
    '$topK',
  ], workingDirectory: pythonRepo);

  if (process.exitCode != 0) {
    stderr.writeln(process.stdout);
    stderr.writeln(process.stderr);
    throw StateError('Python benchmark failed with exit ${process.exitCode}');
  }
  final decoded = jsonDecode(process.stdout as String) as Map<String, dynamic>;
  return _BenchResult.fromJson('python', decoded);
}

void _printTable(_BenchResult dart, _BenchResult python) {
  String fixed(double value) => value.toStringAsFixed(2);
  print('| metric | Dart | Python | speedup |');
  print('|---|---:|---:|---:|');
  print(
    '| build/prewarm ms | ${fixed(dart.buildMs)} | ${fixed(python.buildMs)} | ${fixed(python.buildMs / dart.buildMs)}x |',
  );
  print(
    '| total setup ms | ${fixed(dart.totalSetupMs)} | ${fixed(python.totalSetupMs)} | ${fixed(python.totalSetupMs / dart.totalSetupMs)}x |',
  );
  print(
    '| warm search p50 ms | ${fixed(dart.searchP50Ms)} | ${fixed(python.searchP50Ms)} | ${fixed(python.searchP50Ms / dart.searchP50Ms)}x |',
  );
  print(
    '| warm search p95 ms | ${fixed(dart.searchP95Ms)} | ${fixed(python.searchP95Ms)} | ${fixed(python.searchP95Ms / dart.searchP95Ms)}x |',
  );
  print(
    '| warm search mean ms | ${fixed(dart.searchMeanMs)} | ${fixed(python.searchMeanMs)} | ${fixed(python.searchMeanMs / dart.searchMeanMs)}x |',
  );

  final overlaps = <double>[];
  for (final query in _queries) {
    final dartTop =
        dart.topPaths[query]?.map(_normalizePath).toSet() ?? const {};
    final pyTop =
        python.topPaths[query]?.map(_normalizePath).toSet() ?? const {};
    if (dartTop.isEmpty && pyTop.isEmpty) continue;
    overlaps.add(
      dartTop.intersection(pyTop).length /
          math.max(dartTop.length, pyTop.length),
    );
  }
  if (overlaps.isNotEmpty) {
    final mean = overlaps.reduce((a, b) => a + b) / overlaps.length;
    print(
      '| top-path overlap mean | ${(mean * 100).toStringAsFixed(1)}% | ${(mean * 100).toStringAsFixed(1)}% | n/a |',
    );
  }
}

String _normalizePath(String path) => path.replaceAll('\\', '/');

String? _arg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

String _defaultModelRoot() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('HOME is not set; pass --model explicitly');
  }
  final ref = File(
    p.join(
      home,
      '.cache',
      'huggingface',
      'hub',
      'models--minishlab--potion-code-16M',
      'refs',
      'main',
    ),
  );
  if (!ref.existsSync()) {
    throw StateError('HF model ref missing; pass --model explicitly');
  }
  return p.join(
    home,
    '.cache',
    'huggingface',
    'hub',
    'models--minishlab--potion-code-16M',
    'snapshots',
    ref.readAsStringSync().trim(),
  );
}

double _percentile(List<double> values, double p) {
  final sorted = [...values]..sort();
  final index = ((sorted.length - 1) * p).round();
  return sorted[index];
}

class _BenchResult {
  final String name;
  final double buildMs;
  final double totalSetupMs;
  final double searchP50Ms;
  final double searchP95Ms;
  final double searchMeanMs;
  final Map<String, List<String>> topPaths;

  const _BenchResult({
    required this.name,
    required this.buildMs,
    required this.totalSetupMs,
    required this.searchP50Ms,
    required this.searchP95Ms,
    required this.searchMeanMs,
    required this.topPaths,
  });

  factory _BenchResult.fromJson(String name, Map<String, dynamic> json) {
    return _BenchResult(
      name: name,
      buildMs: (json['build_ms'] as num).toDouble(),
      totalSetupMs: (json['total_setup_ms'] as num).toDouble(),
      searchP50Ms: (json['search_p50_ms'] as num).toDouble(),
      searchP95Ms: (json['search_p95_ms'] as num).toDouble(),
      searchMeanMs: (json['search_mean_ms'] as num).toDouble(),
      topPaths: {
        for (final entry in (json['top_paths'] as Map<String, dynamic>).entries)
          entry.key: (entry.value as List<dynamic>).cast<String>(),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'build_ms': buildMs,
    'total_setup_ms': totalSetupMs,
    'search_p50_ms': searchP50Ms,
    'search_p95_ms': searchP95Ms,
    'search_mean_ms': searchMeanMs,
    'top_paths': topPaths,
  };
}

const _pythonBenchSource = r'''
import argparse
import json
import statistics
import time

from semble import SembleIndex

QUERIES = [
    "authenticate token",
    "parse command line arguments",
    "cache invalidation metadata",
    "tree sitter chunk source files",
    "format search results json",
    "find related code location",
]


def percentile(values, p):
    values = sorted(values)
    return values[round((len(values) - 1) * p)]


parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True)
parser.add_argument("--model", required=True)
parser.add_argument("--rounds", type=int, default=5)
parser.add_argument("--top-k", type=int, default=5)
args = parser.parse_args()

setup_start = time.perf_counter()
build_start = time.perf_counter()
index = SembleIndex.from_path(args.repo, model_path=args.model)
build_ms = (time.perf_counter() - build_start) * 1000.0
total_setup_ms = (time.perf_counter() - setup_start) * 1000.0

timings = []
top_paths = {}
for _ in range(args.rounds):
    for query in QUERIES:
        start = time.perf_counter()
        results = index.search(query, top_k=args.top_k)
        timings.append((time.perf_counter() - start) * 1000.0)
        top_paths.setdefault(query, [r.chunk.file_path for r in results])

print(json.dumps({
    "build_ms": build_ms,
    "total_setup_ms": total_setup_ms,
    "search_p50_ms": percentile(timings, 0.50),
    "search_p95_ms": percentile(timings, 0.95),
    "search_mean_ms": statistics.mean(timings),
    "top_paths": top_paths,
}))
''';
