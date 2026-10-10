import * as crypto from 'node:crypto';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

const MAX_PATTERN_CHARS = 512;
const MAX_RESULT_CHARS = 8192;
const EXPECTED_FORK_FILES = Object.freeze({
  'LICENSE': '35bdd8a44339719441900fb50fbefc5e2dca1ca662cbaed7a687de842c8b70f2',
  'README.md': 'f06ecffb78d40201813ecf840cd06b280a5a56ee85a7f9a6224df3bc1453c53d',
  'index.js': '332ea07c7b006361aad12aa994ca75dc1db8e8382b884909e2f38f10b85c88a4',
  'lib/compile.js': '20ea98b7f04c8969ca478db458e3e08e0f3b47cc9f810a75336370bfedbf9436',
  'lib/constants.js': 'f9fb688959232eee3e6ad7906a5b0e3234815db49ee857ef86983d65b917dc7c',
  'lib/expand.js': '3fb6a53995e05263b594485975c2ac9312e0c3b6b8bf37bd3b4ec6e5deb43a9e',
  'lib/parse.js': '43d983a546dce1ed446dbe8535438a717de9e85040ab701edae3a5a50acdc1d4',
  'lib/stringify.js': 'dd47ae5c9ac1f1a0e65de7160e25500a9dd724279a65fe96011c7f1b7b7ed36c',
  'lib/utils.js': '34b39e1b7d634c5460c30b1fe271dd337cfc383709b3659c31e5d84b12e92e61',
  'package.json': '6a966416d58086ffe4cb6d5f6af14c380953bba178d2865c536a9ecb4dab4e74'
});

function assertPath(value, label) {
  const full = path.resolve(value);
  if (!path.isAbsolute(full) || full.length > 4096) {
    throw new Error(`${label} is not a bounded absolute path`);
  }
  return full;
}

function isWithin(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function packageRootFromEntry(entryPath, expectedName) {
  let current = path.dirname(entryPath);
  for (let step = 0; step < 32; step += 1) {
    const packageJson = path.join(current, 'package.json');
    if (fs.existsSync(packageJson)) {
      const metadata = JSON.parse(fs.readFileSync(packageJson, 'utf8'));
      if (metadata.name === expectedName) return { root: current, metadata };
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error(`Could not identify bounded package root for ${expectedName}`);
}

function walkRegularFiles(root) {
  const output = [];
  const pending = [root];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) throw new Error('Unexpected symlink in installed braces package');
      if (entry.isDirectory()) pending.push(full);
      else if (entry.isFile()) output.push(path.relative(root, full).split(path.sep).join('/'));
      else throw new Error('Unexpected non-regular entry in installed braces package');
      if (output.length + pending.length > 64) throw new Error('Installed braces package exceeds bounded file count');
    }
  }
  return output.sort();
}

function loadRoute(sourceRoot, runtimeRoot) {
  const openspecEntry = path.join(runtimeRoot, 'node_modules', '@fission-ai', 'openspec', 'bin', 'openspec.js');
  if (!fs.existsSync(openspecEntry)) throw new Error('Prepared OpenSpec entry point is unavailable');
  const openspecRequire = createRequire(openspecEntry);
  const fastGlobEntry = openspecRequire.resolve('fast-glob');
  const fastGlobRequire = createRequire(fastGlobEntry);
  const fastGlobModule = openspecRequire('fast-glob');
  const micromatchEntry = fastGlobRequire.resolve('micromatch');
  const micromatchRequire = createRequire(micromatchEntry);
  const micromatchModule = fastGlobRequire('micromatch');
  const bracesEntry = micromatchRequire.resolve('braces');
  const bracesModule = micromatchRequire('braces');
  const openspec = packageRootFromEntry(openspecEntry, '@fission-ai/openspec');
  const fastGlob = packageRootFromEntry(fastGlobEntry, 'fast-glob');
  const micromatch = packageRootFromEntry(micromatchEntry, 'micromatch');
  const braces = packageRootFromEntry(bracesEntry, bracesPackageName(bracesEntry));
  const packagesRoot = path.join(runtimeRoot, 'node_modules');
  for (const [label, entry] of Object.entries({ openspecEntry, fastGlobEntry, micromatchEntry, bracesEntry })) {
    const resolved = fs.realpathSync(entry);
    if (!isWithin(packagesRoot, resolved)) throw new Error(`${label} escaped the prepared runtime package root`);
  }
  const bracesRoot = fs.realpathSync(braces.root);
  if (!isWithin(packagesRoot, bracesRoot)) throw new Error('Resolved braces package escaped the prepared runtime');

  return {
    openspecRequire,
    fastGlobRequire,
    micromatchRequire,
    bracesRequire: micromatchRequire,
    fastGlobModule,
    micromatchModule,
    bracesModule,
    openspecEntry,
    fastGlobEntry,
    micromatchEntry,
    bracesEntry,
    openspec,
    fastGlob,
    micromatch,
    braces,
    sourceRoot,
    repositoryRoot,
    runtimeRoot
  };
}

function bracesPackageName(entryPath) {
  return packageRootFromEntry(entryPath, findPackageName(entryPath)).metadata.name;
}

function findPackageName(entryPath) {
  let current = path.dirname(entryPath);
  for (let step = 0; step < 32; step += 1) {
    const packageJson = path.join(current, 'package.json');
    if (fs.existsSync(packageJson)) {
      const metadata = JSON.parse(fs.readFileSync(packageJson, 'utf8'));
      if (typeof metadata.name === 'string' && metadata.name.length > 0) return metadata.name;
    }
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new Error('Resolved braces entry has no bounded package metadata');
}

function summarizeCall(call) {
  const capturedLogs = [];
  const savedLog = console.log;
  console.log = (...values) => {
    if (capturedLogs.length >= 256) throw new Error('Library emitted too many console records');
    capturedLogs.push(values.map(value => String(value)).join(' ').slice(0, 256));
  };
  try {
    const result = call();
    let resultKind = Array.isArray(result) ? 'array' : result === null ? 'null' : typeof result;
    let resultLength = Array.isArray(result) ? result.length : typeof result === 'string' ? result.length : undefined;
    if (resultLength !== undefined && resultLength > 4096) throw new Error('Library result exceeded the bounded output cardinality');
    if (typeof result === 'string' && result.length > MAX_RESULT_CHARS) throw new Error('Library result exceeded the bounded output size');
    return { accepted: true, resultKind, resultLength, logs: capturedLogs.length };
  } catch (error) {
    return {
      accepted: false,
      errorName: error && typeof error.name === 'string' ? error.name : 'Error',
      errorMessage: String(error && error.message ? error.message : error).slice(0, 240),
      logs: capturedLogs.length
    };
  } finally {
    console.log = savedLog;
  }
}

function buildPattern(kind, depth) {
  if (!Number.isInteger(depth) || depth < 0 || depth > 101) throw new Error('Depth is outside the bounded fixture range');
  let open;
  let close;
  if (kind === 'brace') {
    open = () => '{';
    close = () => '}';
  } else if (kind === 'paren') {
    open = () => '(';
    close = () => ')';
  } else if (kind === 'mixed') {
    open = index => index % 2 === 0 ? '{' : '(';
    close = index => index % 2 === 0 ? '}' : ')';
  } else {
    throw new Error('Unknown bounded pattern kind');
  }
  let pattern = '';
  for (let index = 0; index < depth; index += 1) pattern += open(index);
  pattern += 'x';
  for (let index = depth - 1; index >= 0; index -= 1) pattern += close(index);
  if (pattern.length > MAX_PATTERN_CHARS) throw new Error('Pattern exceeded the bounded fixture size');
  return pattern;
}

function buildParserShapedAst(depth) {
  if (!Number.isInteger(depth) || depth < 0 || depth > 101) throw new Error('AST depth is outside the bounded fixture range');
  const root = { type: 'root', input: '', nodes: [] };
  let parent = root;
  const wrappers = [];
  for (let index = 0; index < depth; index += 1) {
    const wrapper = { type: 'paren', nodes: [] };
    const open = { type: 'text', value: '(' };
    wrapper.parent = parent;
    open.parent = wrapper;
    wrapper.nodes.push(open);
    parent.nodes.push(wrapper);
    parent = wrapper;
    wrappers.push(wrapper);
  }
  if (depth === 0) {
    root.nodes.push({ type: 'text', value: 'x', parent: root });
  } else {
    parent.nodes.push({ type: 'text', value: 'x', parent });
    for (let index = wrappers.length - 1; index >= 0; index -= 1) {
      const close = { type: 'text', value: ')', parent: wrappers[index] };
      wrappers[index].nodes.push(close);
    }
  }
  return root;
}

function runIdentity(route) {
  const packageJson = JSON.parse(fs.readFileSync(path.join(route.sourceRoot, 'package.json'), 'utf8'));
  const packageLock = JSON.parse(fs.readFileSync(path.join(route.sourceRoot, 'package-lock.json'), 'utf8'));
  const lockPackages = packageLock.packages || {};
  const bracesRoot = fs.realpathSync(route.braces.root);
  const installedFiles = walkRegularFiles(bracesRoot);
  const fileHashes = {};
  for (const relative of installedFiles) {
    fileHashes[relative] = crypto.createHash('sha256').update(fs.readFileSync(path.join(bracesRoot, relative))).digest('hex');
  }
  const lockEntry = lockPackages['node_modules/braces'] || {};
  const dependencyRecords = {
    openspec: { version: route.openspec.metadata.version, lockVersion: lockPackages['node_modules/@fission-ai/openspec'] && lockPackages['node_modules/@fission-ai/openspec'].version },
    fastGlob: { version: route.fastGlob.metadata.version, lockVersion: lockPackages['node_modules/fast-glob'] && lockPackages['node_modules/fast-glob'].version },
    micromatch: { version: route.micromatch.metadata.version, lockVersion: lockPackages['node_modules/micromatch'] && lockPackages['node_modules/micromatch'].version },
    braces: { name: route.braces.metadata.name, version: route.braces.metadata.version, license: route.braces.metadata.license, resolved: lockEntry.resolved, integrity: lockEntry.integrity, lockVersion: lockEntry.version }
  };
  return {
    nodeVersion: process.version,
    manifestOverride: packageJson.overrides && packageJson.overrides.braces,
    lockfileVersion: packageLock.lockfileVersion,
    packages: dependencyRecords,
    resolved: {
      openspec: route.openspecEntry,
      fastGlob: route.fastGlobEntry,
      micromatch: route.micromatchEntry,
      braces: route.bracesEntry,
      bracesRoot: bracesRoot
    },
    publishedFileHashes: fileHashes,
    publishedFileNames: installedFiles,
    expectedPublishedFileNames: Object.keys(EXPECTED_FORK_FILES).sort(),
    expectedPublishedFileHashes: EXPECTED_FORK_FILES
  };
}

function runPatterns(route) {
  const rows = [];
  for (const kind of ['brace', 'paren', 'mixed']) {
    for (const depth of [100, 101]) {
      const pattern = buildPattern(kind, depth);
      for (const method of ['parse', 'compile', 'expand', 'stringify']) {
        rows.push({ kind, depth, method, ...summarizeCall(() => route.bracesModule[method](pattern)) });
      }
    }
  }
  return { rows };
}

function runAst(route) {
  const rows = [];
  for (const depth of [100, 101]) {
    for (const method of ['compile', 'expand', 'stringify']) {
      const ast = buildParserShapedAst(depth);
      rows.push({ depth, method, ...summarizeCall(() => route.bracesModule[method](ast)) });
    }
  }
  return { rows };
}

function runOptions(route) {
  const rows = [];
  const options = [
    { label: 'infinity', value: Infinity },
    { label: 'nan', value: NaN },
    { label: 'large-cap', value: 10000 }
  ];
  for (const option of options) {
    for (const depth of [100, 101]) {
      const pattern = buildPattern('brace', depth);
      for (const method of ['parse', 'compile', 'expand', 'stringify']) {
        rows.push({ option: option.label, depth, method, ...summarizeCall(() => route.bracesModule[method](pattern, { maxDepth: option.value })) });
      }
    }
    for (const method of ['compile', 'expand', 'stringify']) {
      const ast = buildParserShapedAst(101);
      rows.push({ option: `ast-${option.label}`, depth: 101, method, ...summarizeCall(() => route.bracesModule[method](ast, { maxDepth: option.value })) });
    }
  }
  for (const method of ['parse', 'compile', 'expand', 'stringify']) {
    rows.push({ option: 'zero-flat', depth: 0, method, ...summarizeCall(() => route.bracesModule[method]('x', { maxDepth: 0 })) });
    rows.push({ option: 'zero-nested', depth: 1, method, ...summarizeCall(() => route.bracesModule[method]('{x}', { maxDepth: 0 })) });
    rows.push({ option: 'negative', depth: 0, method, ...summarizeCall(() => route.bracesModule[method]('x', { maxDepth: -1 })) });
  }
  return { rows };
}

function runCompatibility(route) {
  const braces = route.bracesModule;
  const fastGlob = route.fastGlobModule;
  const micromatch = route.micromatchModule;
  const files = fastGlob.sync('tests/fixtures/{confluence-runtime-depth-guard.mjs,confluence-runtime-depth-guard-no-match.mjs}', {
    cwd: route.repositoryRoot,
    onlyFiles: true,
    followSymbolicLinks: false
  }).map(value => value.split(path.sep).join('/')).sort();
  return {
    listExpansion: braces.expand('a/{b,c}/d'),
    rangeExpansion: braces.expand('{1..3}'),
    escapedBraceLiteral: braces.expand(String.raw`a/\{b,c\}`),
    micromatchExpansion: [
      micromatch.isMatch('assets/a.css', 'assets/{a,b}.css'),
      micromatch.isMatch('assets/c.css', 'assets/{a,b}.css')
    ],
    fastGlobFiles: files
  };
}

function main() {
  const [mode, sourceRootValue, runtimeRootValue] = process.argv.slice(2);
  if (!['identity', 'patterns', 'ast', 'options', 'compatibility'].includes(mode)) throw new Error('Unknown fixture mode');
  const sourceRoot = assertPath(sourceRootValue, 'source root');
  const runtimeRoot = assertPath(runtimeRootValue, 'runtime root');
  const route = loadRoute(sourceRoot, runtimeRoot);
  let payload;
  if (mode === 'identity') payload = runIdentity(route);
  else if (mode === 'patterns') payload = runPatterns(route);
  else if (mode === 'ast') payload = runAst(route);
  else if (mode === 'options') payload = runOptions(route);
  else payload = runCompatibility(route);
  const output = JSON.stringify({ mode, ...payload });
  if (output.length > MAX_RESULT_CHARS) throw new Error('Fixture summary exceeded the bounded output size');
  process.stdout.write(`${output}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${String(error && error.message ? error.message : error).slice(0, 512)}\n`);
  process.exitCode = 1;
}
