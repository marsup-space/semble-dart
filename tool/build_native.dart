/// Build `libcrux_grammars.[ext]` — a single shared library that
/// statically links `libtree-sitter` runtime + the 9 supported
/// language grammars (dart, python, javascript, typescript, go,
/// rust, java, cpp, ruby, php). Each grammar exports its own
/// `tree_sitter_<lang>()` symbol; Dart looks them up by name at
/// runtime via `dart:ffi`.
///
/// This is a maintainer tool: invoked locally before a release to
/// produce binaries that get uploaded to GitHub releases. End users
/// never run this; they fetch the prebuilt binaries via the existing
/// `tool/third_party.dart` manifest flow.
///
/// Usage:
///   dart run tool/build_native.dart                    # build for current host
///   dart run tool/build_native.dart --target all        # build all targets
///   dart run tool/build_native.dart --target linux-x64  # specific target
///   dart run tool/build_native.dart --list-grammars     # show the grammar list
///   dart run tool/build_native.dart --clean             # wipe grammar clones
///
/// Output:
///   `third_party/bin/[target]/libcrux_grammars.{so,dylib,dll}`
library;

import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Spec for a single grammar. Some grammars (TypeScript) ship
/// multiple sub-grammars in one repo (typescript + tsx); others
/// expose a single entry point.
class _GrammarSpec {
  /// GitHub repo (org/name).
  final String repo;

  /// Source sub-paths within the cloned repo. Each produces its own
  /// object file and links its own `tree_sitter_*` entry point. The
  /// first source is the canonical `tree_sitter_<name>` entry.
  final List<_SourceSpec> sources;

  const _GrammarSpec({required this.repo, required this.sources});
}

class _SourceSpec {
  /// Sub-directory holding `parser.c` and (optionally) `scanner.c`.
  final String subDir;

  /// Name of the `tree_sitter_<x>(void)` C function. Defaults to
  /// `tree_sitter_<grammarName>` for the first source; sub-sources
  /// must specify explicitly.
  final String entryPoint;

  const _SourceSpec(this.subDir, {required this.entryPoint});
}

const _grammarRepos = <String, _GrammarSpec>{
  // The Dart grammar is not under the tree-sitter org — it's
  // maintained at UserNobody14/tree-sitter-dart (the canonical fork).
  'dart': _GrammarSpec(
    repo: 'UserNobody14/tree-sitter-dart',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_dart')],
  ),
  'python': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-python',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_python')],
  ),
  'javascript': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-javascript',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_javascript')],
  ),
  // TypeScript ships two sub-grammars: pure TS and TSX. Both must
  // be compiled and linked — they share common/ headers.
  'typescript': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-typescript',
    sources: [
      _SourceSpec('typescript/src', entryPoint: 'tree_sitter_typescript'),
      _SourceSpec('tsx/src', entryPoint: 'tree_sitter_tsx'),
    ],
  ),
  'go': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-go',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_go')],
  ),
  'rust': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-rust',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_rust')],
  ),
  'java': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-java',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_java')],
  ),
  'cpp': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-cpp',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_cpp')],
  ),
  'ruby': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-ruby',
    sources: [_SourceSpec('src', entryPoint: 'tree_sitter_ruby')],
  ),
  // PHP ships two sub-grammars: full PHP (with HTML embedded) and
  // pure-PHP. Both must be compiled and linked — they share
  // common/ headers.
  'php': _GrammarSpec(
    repo: 'tree-sitter/tree-sitter-php',
    sources: [
      _SourceSpec('php/src', entryPoint: 'tree_sitter_php'),
      _SourceSpec('php_only/src', entryPoint: 'tree_sitter_php_only'),
    ],
  ),
};

/// libtree-sitter core. Pinned to a specific tag so grammar ABI matches.
/// v0.26.10 is the latest stable as of 2026-06; the grammars we ship
/// (especially `UserNobody14/tree-sitter-dart`) declare
/// `LANGUAGE_VERSION = 15` or higher, which requires runtime >= 14.
/// v0.20.8 (the original choice) only supports version 14, so
/// `ts_parser_set_language` rejects newer grammars and parse returns
/// NULL silently. Bump to a current release.
const _treeSitterRepo = 'tree-sitter/tree-sitter';
const _treeSitterTag = 'v0.26.10';

/// Host → target identifier. Matches the existing `targetRuntimeTarget`
/// convention in Crux's `bundled_executable.dart`.
const _hostTargets = <String, String>{
  'darwin-arm64': 'macos-arm64',
  'darwin-x64': 'macos-x64',
  'linux-arm64': 'linux-arm64',
  'linux-x64': 'linux-x64',
  'windows-arm64': 'windows-arm64',
  'windows-x64': 'windows-x64',
};

const _libExtension = <String, String>{
  'macos-arm64': 'dylib',
  'macos-x64': 'dylib',
  'linux-arm64': 'so',
  'linux-x64': 'so',
  'windows-arm64': 'dll',
  'windows-x64': 'dll',
};

Future<int> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts.showHelp) {
    _printUsage();
    return 0;
  }
  if (opts.listGrammars) {
    _printGrammars();
    return 0;
  }
  if (opts.clean) {
    await _clean();
    return 0;
  }

  final targets = opts.targets;
  if (targets.isEmpty) {
    stderr.writeln('No targets specified (use --target or run with no args for current host).');
    return 64;
  }

  for (final target in targets) {
    stdout.writeln('=== building for $target ===');
    final ok = await _buildTarget(target);
    if (!ok) {
      stderr.writeln('build failed for $target');
      return 1;
    }
  }
  return 0;
}

// =============================================================================
// Build orchestration
// =============================================================================

Future<bool> _buildTarget(String target) async {
  final ext = _libExtension[target];
  if (ext == null) {
    stderr.writeln('unknown target: $target');
    return false;
  }

  // Resolve cc — most platforms have it. Windows would need cl.exe
  // (out of scope for v1; we'll fail clearly with a hint).
  final cc = _resolveCc(target);
  if (cc == null) {
    stderr.writeln('no C compiler found for $target (need cc/clang on POSIX)');
    return false;
  }

  // Layout:
  //   .build/grammars-src/<lang>/   ← clone of the grammar repo
  //   .build/tree-sitter/           ← clone of libtree-sitter
  //   .build/<target>/              ← per-target object files + output
  final buildRoot = Directory(p.join('.build'));
  final grammarsDir = Directory(p.join('.build', 'grammars-src'));
  final tsDir = Directory(p.join('.build', 'tree-sitter'));
  final objDir = Directory(p.join('.build', target));
  final outDir = Directory(p.join('third_party', 'bin', target));

  await _ensure(buildRoot);
  await _ensure(grammarsDir);
  await _ensure(tsDir);
  await _ensure(objDir);
  await _ensure(outDir);

  // Step 1: clone libtree-sitter at the pinned tag.
  stdout.writeln('  → checking out libtree-sitter @ $_treeSitterTag');
  if (!await _ensureClone(tsDir, _treeSitterRepo, _treeSitterTag)) {
    return false;
  }

  // Step 2: clone each grammar at its latest commit on the default branch.
  for (final entry in _grammarRepos.entries) {
    stdout.writeln('  → checking out grammar: ${entry.key}');
    if (!await _ensureClone(
      Directory(p.join(grammarsDir.path, entry.key)),
      entry.value.repo,
      null, // default branch HEAD
    )) {
      return false;
    }
  }

  // Step 3: compile libtree-sitter core → lib.o
  stdout.writeln('  → cc -c libtree-sitter/lib/src/lib.c');
  final tsLibObj = p.join(objDir.path, 'lib.o');
  final tsSrc = File(p.join(tsDir.path, 'lib', 'src', 'lib.c'));
  if (!await _run(
    cc,
    [
      '-c', '-fPIC', '-O2',
      '-I', p.join(tsDir.path, 'lib', 'include'),
      '-o', tsLibObj,
      tsSrc.path,
    ],
  )) {
    return false;
  }

  // Step 4: compile each grammar's source(s) → <lang>-<sub>.o
  // Some grammars (TypeScript) have multiple sub-sources that share
  // the repo's `common/` headers — both must be linked.
  final grammarObjs = <String>[];
  for (final entry in _grammarRepos.entries) {
    final lang = entry.key;
    final spec = entry.value;
    final grammarDir = Directory(p.join(grammarsDir.path, lang));

    for (var i = 0; i < spec.sources.length; i++) {
      final src = spec.sources[i];
      final srcDir = Directory(p.join(grammarDir.path, src.subDir));
      final parserC = File(p.join(srcDir.path, 'parser.c'));
      final scannerC = File(p.join(srcDir.path, 'scanner.c'));

      if (!parserC.existsSync()) {
        stderr.writeln('  ⚠ $lang/${src.subDir}: missing parser.c at ${parserC.path}');
        return false;
      }

      // Object file name: <lang>.o for the first source, <lang>-<sub>.o
      // for subsequent ones (typescript.tsx.o, etc.). The grammar's
      // include path is the FIRST source's directory (and `common/`
      // for multi-source grammars).
      final objName = i == 0
          ? '$lang.o'
          : '$lang-${p.basename(src.subDir)}.o';
      final obj = p.join(objDir.path, objName);
      final includePaths = <String>[
        srcDir.path,
        // Multi-source grammars (TypeScript) share common headers
        // in the repo root, not the src sub-directory.
        if (spec.sources.length > 1)
          Directory(p.join(grammarDir.path, 'common')).path,
        p.join(tsDir.path, 'lib', 'include'),
      ];
      stdout.writeln('  → cc -c $lang/${src.subDir}/parser.c');
      if (!await _run(cc, [
        '-c', '-fPIC', '-O2',
        for (final ip in includePaths) '-I$ip',
        '-o', obj,
        parserC.path,
      ])) {
        return false;
      }
      if (scannerC.existsSync()) {
        stdout.writeln('  → cc -c $lang/${src.subDir}/scanner.c (external scanner)');
        final scannerObj = p.join(objDir.path, '$objName-scanner');
        if (!await _run(cc, [
          '-c', '-fPIC', '-O2',
          for (final ip in includePaths) '-I$ip',
          '-o', scannerObj,
          scannerC.path,
        ])) {
          return false;
        }
        grammarObjs.add(scannerObj);
      }
      grammarObjs.add(obj);
    }
  }

  // Step 4.5: compile the Dart-FFI shim. Adds `crux_ts_tree_root_node`
  // which wraps `ts_tree_root_node` (32-byte struct return) into an
  // out-parameter form Dart FFI can call. See native/crux_treesitter.c.
  stdout.writeln('  → cc -c native/crux_treesitter.c (Dart FFI shim)');
  final shimObj = p.join(objDir.path, 'crux_treesitter.o');
  final shimSrc = File('native/crux_treesitter.c');
  if (!shimSrc.existsSync()) {
    stderr.writeln('  ⚠ missing shim: ${shimSrc.path}');
    return false;
  }
  if (!await _run(cc, [
    '-c', '-fPIC', '-O2',
    '-I', p.join(tsDir.path, 'lib', 'include'),
    '-o', shimObj,
    shimSrc.path,
  ])) {
    return false;
  }

  // Step 5: link into a shared library. Export ALL symbols so the
  // runtime can find both libtree-sitter entry points (ts_parser_new,
  // etc.) and the grammar entry points (tree_sitter_<lang>).
  //
  // We use `-Wl,-u,_<sym>` to force the linker to keep specific
  // symbols (the shim) that nothing else in the dylib references —
  // otherwise the linker dead-strips the entire .o file.
  final outPath = p.join(outDir.path, 'libcrux_grammars.$ext');
  stdout.writeln('  → cc -shared -o $outPath');
  final linkArgs = <String>[
    '-shared',
    '-O2',
    if (target.startsWith('macos'))
      '-Wl,-export_dynamic'
    else
      '-Wl,--export-dynamic',
    // Force-keep the shim — it's the only caller of
    // `crux_ts_tree_root_node` and the linker would otherwise drop
    // the shim's .o file as dead code.
    '-Wl,-u,_crux_ts_tree_root_node_alloc',
    '-Wl,-u,_crux_ts_tree_root_node_free',
    '-Wl,-u,_crux_ts_node_type',
    '-Wl,-u,_crux_ts_node_child_free',
    '-o', outPath,
    tsLibObj,
    shimObj,
    ...grammarObjs,
  ];
  if (target == 'linux-arm64' || target == 'linux-x64') {
    // Linux needs libstdc++ for the C++ scanners in some grammars
    // (tree-sitter-cpp uses C++ in its scanner.c).
    linkArgs.add('-lstdc++');
  }
  if (!await _run(cc, linkArgs)) {
    return false;
  }

  // Step 6: SHA-256 for manifest pinning.
  final sha = await _sha256(outPath);
  stdout.writeln('');
  stdout.writeln('  ✔ built: $outPath');
  stdout.writeln('    sha256: $sha');
  stdout.writeln('    size:   ${(File(outPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
  stdout.writeln('');
  return true;
}

// =============================================================================
// Plumbing
// =============================================================================

class _Opts {
  bool showHelp = false;
  bool listGrammars = false;
  bool clean = false;
  List<String> targets = const [];
}

_Opts _parseArgs(List<String> args) {
  final opts = _Opts();
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '-h':
      case '--help':
        opts.showHelp = true;
      case '--list-grammars':
        opts.listGrammars = true;
      case '--clean':
        opts.clean = true;
      case '--target':
        final v = (i + 1 < args.length) ? args[++i] : '';
        opts.targets = v == 'all'
            ? _hostTargets.values.toList()
            : v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      default:
        stderr.writeln('unknown arg: $a');
        opts.showHelp = true;
    }
  }
  // No --target → default to current host.
  if (opts.targets.isEmpty && !opts.showHelp && !opts.listGrammars && !opts.clean) {
    final host = _detectHost();
    if (host != null) {
      opts.targets = [_hostTargets[host]!];
    }
  }
  return opts;
}

String? _detectHost() {
  // Use Abi.current() — Platform.isMacArm64 / Platform.isAarch64
  // don't exist on stable Dart yet.
  switch (Abi.current()) {
    case Abi.macosArm64:
      return 'darwin-arm64';
    case Abi.macosX64:
      return 'darwin-x64';
    case Abi.linuxArm64:
      return 'linux-arm64';
    case Abi.linuxX64:
      return 'linux-x64';
    case Abi.windowsArm64:
      return 'windows-arm64';
    case Abi.windowsX64:
      return 'windows-x64';
    default:
      return null;
  }
}

String? _resolveCc(String target) {
  // POSIX: prefer clang, fall back to cc/gcc. Windows: cl.exe (not
  // implemented in v1; we surface the error clearly).
  if (target.startsWith('windows')) {
    final cl = _which('cl.exe');
    if (cl != null) return cl;
    return null;
  }
  return _which('clang') ?? _which('cc') ?? _which('gcc');
}

String? _which(String name) {
  final result = Process.runSync('which', [name]);
  if (result.exitCode == 0) {
    final p = (result.stdout as String).trim();
    return p.isEmpty ? null : p;
  }
  return null;
}

Future<bool> _ensureClone(Directory dir, String repo, String? tag) async {
  // Idempotency check: any non-empty clone has a `.git/` directory.
  // We can't look for `src/` because libtree-sitter's source is at
  // `lib/src/`, and grammars can have different layouts.
  if (dir.existsSync() && Directory(p.join(dir.path, '.git')).existsSync()) {
    return true;
  }
  await _ensure(dir.parent);

  // Use SSH URLs unconditionally. On many networks (China, behind
  // corporate firewalls) github.com is unreachable via HTTPS even
  // though the SSH endpoint routes around the blockage. The user
  // is expected to have `~/.ssh/config` set up or `gh auth login`
  // with ssh protocol (we default to ssh in `gh auth status`).
  //
  // Override: set `SEMBLE_GIT_HTTPS=1` to fall back to HTTPS.
  final useHttps = Platform.environment['SEMBLE_GIT_HTTPS'] == '1';
  final cloneUrl = useHttps
      ? 'https://github.com/$repo.git'
      : 'git@github.com:$repo.git';
  // ignore: use_null_aware_elements
  final args = <String>[
    'clone', '--depth', '1',
    if (tag != null) ...<String>['--branch', tag],
    cloneUrl, dir.path,
  ];
  stdout.writeln('    git clone ${args.sublist(1).join(' ')}');
  return await _run('git', args);
}

Future<bool> _run(String exe, List<String> args) async {
  final result = await Process.run(exe, args);
  if (result.exitCode != 0) {
    stderr.writeln('  ✖ $exe ${args.join(' ')}');
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
    return false;
  }
  return true;
}

Future<void> _ensure(Directory d) async {
  if (!d.existsSync()) await d.create(recursive: true);
}

Future<String> _sha256(String path) async {
  // Use package:crypto — no need to shell out to shasum/sha256sum
  // (different binaries on macOS vs Linux anyway).
  final bytes = await File(path).readAsBytes();
  return sha256.convert(bytes).toString();
}

Future<void> _clean() async {
  final buildRoot = Directory('.build');
  if (buildRoot.existsSync()) {
    await buildRoot.delete(recursive: true);
    stdout.writeln('removed ${buildRoot.path}');
  } else {
    stdout.writeln('.build/ does not exist, nothing to clean');
  }
}

void _printUsage() {
  stdout.writeln('''
build_native.dart — compile libcrux_grammars for one or more targets

Usage:
  dart run tool/build_native.dart                       # current host
  dart run tool/build_native.dart --target <list>       # e.g. macos-arm64,linux-x64
  dart run tool/build_native.dart --target all
  dart run tool/build_native.dart --list-grammars
  dart run tool/build_native.dart --clean
''');
}

void _printGrammars() {
  stdout.writeln('Grammars compiled into libcrux_grammars:');
  for (final entry in _grammarRepos.entries) {
    final spec = entry.value;
    for (final src in spec.sources) {
      stdout.writeln('  ${entry.key.padRight(12)} ${src.entryPoint}()  ← ${spec.repo}');
    }
  }
  stdout.writeln('');
  stdout.writeln('Plus libtree-sitter runtime: $_treeSitterRepo @ $_treeSitterTag');
}