// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const expected = Object.freeze({ openspec: '1.13.0', markdownIt: '14.3.1' });
const maxRequestBytes = 1024 * 1024;
const maxSourceBytes = 2 * 1024 * 1024;
const changeIdPattern = /^[a-z][a-z0-9-]{0,99}$/;
const idPattern = /^\[([A-Z][A-Z0-9]*-(REQ|SCN)-[0-9]{3,})\](?:\s+|$)/;

function diagnostic(code, file, line, message) {
  return { code, path: file, line, message };
}

function invalid(code, message) {
  return { status: 'invalid', reasonCodes: [code], diagnostics: [diagnostic(code, '', 0, message)], nativeValidation: { valid: false }, requirements: [], scenarios: [] };
}

async function readRequest() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > maxRequestBytes) throw new Error('RequestTooLarge');
    chunks.push(chunk);
  }
  const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!value || value.operation !== 'validateOpenSpec' || typeof value.root !== 'string' || typeof value.changeId !== 'string') throw new Error('InvalidRequest');
  return value;
}

function readUtf8(file) {
  const bytes = fs.readFileSync(file);
  if (bytes.length > maxSourceBytes) throw new Error('SourceTooLarge');
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

function within(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function relativePath(root, target) {
  return path.relative(root, target).split(path.sep).join('/');
}

function runtimePackages(runtimeRoot) {
  const cli = path.join(runtimeRoot, 'node_modules', '@fission-ai', 'openspec', 'bin', 'openspec.js');
  const openspecPackage = path.join(runtimeRoot, 'node_modules', '@fission-ai', 'openspec', 'package.json');
  const markdownPackage = path.join(runtimeRoot, 'node_modules', 'markdown-it', 'package.json');
  if (!fs.existsSync(cli) || !fs.existsSync(openspecPackage)) return { error: invalid('ValidatorUnavailable', 'The fixed OpenSpec validator is absent from the selected runtime.') };
  const openspecVersion = JSON.parse(readUtf8(openspecPackage)).version;
  if (openspecVersion !== expected.openspec) return { error: invalid('ValidatorVersionMismatch', `Expected OpenSpec ${expected.openspec}.`) };
  if (!fs.existsSync(markdownPackage)) return { error: invalid('ParserUnavailable', 'The fixed Markdown parser is absent from the selected runtime.') };
  const markdownVersion = JSON.parse(readUtf8(markdownPackage)).version;
  if (markdownVersion !== expected.markdownIt) return { error: invalid('ParserVersionMismatch', `Expected markdown-it ${expected.markdownIt}.`) };
  const requireFromRuntime = createRequire(path.join(runtimeRoot, 'package.json'));
  return { cli, MarkdownIt: requireFromRuntime('markdown-it') };
}

function nativeValidate(cli, root, changeId) {
  const allowedEnvironment = {};
  for (const key of ['PATH', 'Path', 'SystemRoot', 'TEMP', 'TMP']) {
    if (process.env[key]) allowedEnvironment[key] = process.env[key];
  }
  Object.assign(allowedEnvironment, { CI: '1', OPENSPEC_TELEMETRY: '0', OPENSPEC_NO_UPDATE_CHECK: '1' });
  const result = spawnSync(process.execPath, [cli, 'validate', changeId, '--type', 'change', '--strict', '--json', '--no-interactive'], {
    cwd: root, env: allowedEnvironment, encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error) return { valid: false, error: result.error.code || 'ValidatorProcessFailed', issues: [] };
  let output;
  try { output = JSON.parse(result.stdout); }
  catch { return { valid: false, error: 'ValidatorOutputInvalid', issues: [] }; }
  const item = output.items?.find(entry => entry.id === changeId && entry.type === 'change');
  return { valid: result.status === 0 && item?.valid === true, exitCode: result.status, issues: item?.issues || [] };
}

function artifactPaths(root, changeId) {
  const changeRoot = path.join(root, 'openspec', 'changes', changeId);
  const specsRoot = path.join(changeRoot, 'specs');
  const required = [
    path.join(root, 'openspec', 'config.yaml'),
    path.join(changeRoot, '.openspec.yaml'),
    ...['proposal.md', 'design.md', 'tasks.md'].map(name => path.join(changeRoot, name)),
  ];
  if (!fs.existsSync(specsRoot)) throw new Error('SpecDirectoryMissing');
  const specPaths = fs.readdirSync(specsRoot, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(specsRoot, entry.name, 'spec.md'));
  if (specPaths.length === 0) throw new Error('SpecDirectoryMissing');
  for (const file of [...required, ...specPaths]) {
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) throw new Error(`SourceArtifactMissing:${relativePath(root, file)}`);
  }
  return { required, specPaths };
}

function headingText(tokens, index) {
  return tokens[index + 1]?.content?.trim() || '';
}

const transparentBlockTokenTypes = new Set([
  'heading_close', 'paragraph_open', 'paragraph_close', 'inline',
  'bullet_list_open', 'bullet_list_close', 'ordered_list_open', 'ordered_list_close',
  'list_item_open', 'list_item_close',
]);
const scaffoldHeadingPattern = /^(?:ADDED|MODIFIED|REMOVED|RENAMED) Requirements$/;

function addUnsupportedBlockDiagnostic(diagnostics, file, token) {
  diagnostics.push({
    ...diagnostic('UnsupportedBlockToken', file, (token.map?.[0] || 0) + 1, 'This Markdown block cannot be projected without loss.'),
    type: token.type,
  });
}

function gwtFromInline(token) {
  const children = token.children || [];
  let start = 0;
  while (children[start]?.type === 'text' && !children[start].content.trim()) start++;
  if (children[start]?.type !== 'strong_open' || children[start + 1]?.type !== 'text' || children[start + 2]?.type !== 'strong_close') return null;
  const keyword = children[start + 1].content.trim().toUpperCase();
  if (!['GIVEN', 'WHEN', 'THEN'].includes(keyword)) return null;
  const value = children.slice(start + 3).filter(child => child.type === 'text' || child.type === 'code_inline').map(child => child.content).join('').trim();
  return { keyword, value };
}

function inlineParts(token, file) {
  const parts = [];
  const children = token.children || [];
  for (let index = 0; index < children.length; index++) {
    const child = children[index];
    if (child.type === 'link_open') {
      const label = [];
      let close = index + 1;
      while (close < children.length && children[close].type !== 'link_close') {
        if (children[close].type === 'text' || children[close].type === 'code_inline') label.push(children[close].content);
        close++;
      }
      parts.push({ type: 'link', href: child.attrGet('href'), text: label.join(''),
        children: inlineParts({ children: children.slice(index + 1, close), map: token.map }, file),
        path: file, line: (token.map?.[0] || 0) + 1 });
      index = close;
    } else if (child.type === 'image') {
      parts.push({ type: 'image', src: child.attrGet('src'), alt: child.content, path: file, line: (token.map?.[0] || 0) + 1 });
    } else if (child.type === 'text' || child.type === 'code_inline') {
      parts.push({ type: child.type === 'code_inline' ? 'code' : 'text', text: child.content });
    } else if (child.type === 'softbreak' || child.type === 'hardbreak') {
      parts.push({ type: 'text', text: '\n' });
    } else if (['strong_open', 'strong_close', 'em_open', 'em_close'].includes(child.type)) {
      parts.push({ type: child.type });
    } else {
      parts.push({ type: 'unsupported', sourceType: child.type, path: file, line: (token.map?.[0] || 0) + 1 });
    }
  }
  return parts;
}

function specInventory(md, root, specPath, diagnostics, requirements, scenarios) {
  const file = relativePath(root, specPath);
  const tokens = md.parse(readUtf8(specPath), {});
  let requirement = null;
  let scenario = null;
  const headingInlineIndices = new Set();
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index];
    if (token.type === 'heading_open') {
      headingInlineIndices.add(index + 1);
      const title = headingText(tokens, index);
      const line = (token.map?.[0] || 0) + 1;
      if (token.tag === 'h3' && title.startsWith('Requirement:')) {
        const name = title.slice('Requirement:'.length).trim();
        const match = idPattern.exec(name);
        if (!match || match[2] !== 'REQ') diagnostics.push(diagnostic('MissingRequirementId', file, line, 'Requirement title needs a stable REQ ID.'));
        requirement = { id: match?.[1] || null, title: name, path: file, line, body: [], bodyBlocks: [], links: [], images: [] };
        requirements.push(requirement);
        scenario = null;
      } else if (token.tag === 'h4' && title.startsWith('Scenario:')) {
        const name = title.slice('Scenario:'.length).trim();
        const match = idPattern.exec(name);
        if (!match || match[2] !== 'SCN') diagnostics.push(diagnostic('MissingScenarioId', file, line, 'Scenario title needs a stable SCN ID.'));
        scenario = { id: match?.[1] || null, requirementId: requirement?.id || null, title: name, path: file, line, given: [], when: [], then: [], links: [], images: [] };
        scenarios.push(scenario);
      } else if (token.tag === 'h3' || token.tag === 'h4') {
        if (scenario || requirement) {
          addUnsupportedBlockDiagnostic(diagnostics, file, token);
        }
        scenario = null;
        if (token.tag === 'h3') requirement = null;
      } else if ((scenario || requirement) && !(token.tag === 'h2' && scaffoldHeadingPattern.test(title))) {
        addUnsupportedBlockDiagnostic(diagnostics, file, token);
      }
      continue;
    }
    const owner = scenario || requirement;
    if (owner && !transparentBlockTokenTypes.has(token.type) && !token.type.endsWith('_close')) {
      addUnsupportedBlockDiagnostic(diagnostics, file, token);
    }
    if (token.type === 'inline' && !headingInlineIndices.has(index)) {
      if (owner) {
        const children = token.children || [];
        for (let childIndex = 0; childIndex < children.length; childIndex++) {
          if (children[childIndex].type === 'image') {
            owner.images.push({ src: children[childIndex].attrGet('src'), alt: children[childIndex].content,
              path: file, line: (token.map?.[0] || 0) + 1 });
          }
          if (children[childIndex].type !== 'link_open') continue;
          const href = children[childIndex].attrGet('href');
          const label = [];
          for (let next = childIndex + 1; next < children.length && children[next].type !== 'link_close'; next++) {
            if (children[next].type === 'text' || children[next].type === 'code_inline') label.push(children[next].content);
          }
          owner.links.push({ href, label: label.join(''), path: file, line: (token.map?.[0] || 0) + 1 });
        }
      }
      if (scenario) {
        const gwt = gwtFromInline(token);
        if (gwt) scenario[gwt.keyword.toLowerCase()].push(gwt.value);
      } else if (requirement && token.content.trim()) {
        const content = (token.children || [])
          .filter(child => child.type === 'text' || child.type === 'code_inline')
          .map(child => child.content).join('').trim();
        if (content) requirement.body.push(content);
        if ((token.children || []).length > 0) requirement.bodyBlocks.push({ parts: inlineParts(token, file), path: file, line: (token.map?.[0] || 0) + 1 });
      }
    }
  }
  for (const item of scenarios.filter(entry => entry.path === file)) {
    if (item.when.length === 0 || item.when.some(value => !value)) diagnostics.push(diagnostic('MissingWhen', file, item.line, 'Scenario WHEN is absent or empty.'));
    if (item.then.length === 0 || item.then.some(value => !value)) diagnostics.push(diagnostic('MissingThen', file, item.line, 'Scenario THEN is absent or empty.'));
  }
}

function references(md, root, sourcePath, diagnostics) {
  const file = relativePath(root, sourcePath);
  const tokens = md.parse(readUtf8(sourcePath), {});
  const discovered = [];
  for (const token of tokens) {
    if (token.type !== 'inline') continue;
    for (const child of token.children || []) {
      if (child.type !== 'link_open' && child.type !== 'image') continue;
      const raw = child.attrGet(child.type === 'image' ? 'src' : 'href');
      if (!raw || raw.startsWith('#')) continue;
      const line = (token.map?.[0] || 0) + 1;
      if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) {
        if (!/^(https?:|mailto:)/i.test(raw)) diagnostics.push(diagnostic('UnsafeReference', file, line, 'Unsupported reference scheme.'));
        continue;
      }
      if (raw.startsWith('//') || path.isAbsolute(raw)) {
        diagnostics.push(diagnostic('UnsafeReference', file, line, 'Reference must remain inside the selected source root.'));
        continue;
      }
      let decoded;
      try { decoded = decodeURIComponent(raw.split(/[?#]/, 1)[0]); }
      catch { diagnostics.push(diagnostic('UnsafeReference', file, line, 'Malformed reference encoding.')); continue; }
      const target = path.resolve(path.dirname(sourcePath), decoded);
      if (!within(root, target)) { diagnostics.push(diagnostic('UnsafeReference', file, line, 'Reference escapes the selected source root.')); continue; }
      if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
        diagnostics.push(diagnostic('ReferenceMissing', file, line, 'Local reference does not resolve at this source revision.'));
        continue;
      }
      if (!within(root, fs.realpathSync.native(target))) { diagnostics.push(diagnostic('UnsafeReference', file, line, 'Reference resolves outside the selected source root.')); continue; }
      discovered.push(target);
    }
  }
  return discovered;
}

function duplicates(items, kind, diagnostics) {
  const seen = new Map();
  for (const item of items) {
    if (!item.id) continue;
    if (seen.has(item.id)) diagnostics.push(diagnostic(`Duplicate${kind}Id`, item.path, item.line, `Stable ${kind.toLowerCase()} ID is repeated.`));
    else seen.set(item.id, item);
  }
}

function digest(root, files) {
  const hash = crypto.createHash('sha256');
  for (const file of [...new Set(files)].sort((a, b) => relativePath(root, a).localeCompare(relativePath(root, b), 'en'))) {
    hash.update(relativePath(root, file)); hash.update('\0'); hash.update(fs.readFileSync(file)); hash.update('\0');
  }
  return hash.digest('hex');
}

function validate(request, runtimeRoot) {
  if (!path.isAbsolute(request.root) || !changeIdPattern.test(request.changeId)) return invalid('InvalidSourceSelection', 'Source root and change ID must be exact.');
  if (!path.isAbsolute(runtimeRoot)) return invalid('ValidatorUnavailable', 'Runtime root must be absolute.');
  const root = fs.realpathSync.native(request.root);
  const runtime = runtimePackages(runtimeRoot);
  if (runtime.error) return runtime.error;
  const nativeValidation = nativeValidate(runtime.cli, root, request.changeId);
  const md = new runtime.MarkdownIt({ html: false, linkify: false, typographer: false });
  const diagnostics = [];
  if (!nativeValidation.valid) diagnostics.push(diagnostic('NativeValidationFailed', '', 0, 'Official strict validation failed.'));
  const { required, specPaths } = artifactPaths(root, request.changeId);
  const requirements = [];
  const scenarios = [];
  for (const specPath of specPaths) specInventory(md, root, specPath, diagnostics, requirements, scenarios);
  duplicates(requirements, 'Requirement', diagnostics);
  duplicates(scenarios, 'Scenario', diagnostics);
  const sourcePaths = [...required, ...specPaths];
  const linked = sourcePaths.flatMap(file => references(md, root, file, diagnostics));
  const reasonCodes = [...new Set(diagnostics.map(item => item.code))];
  return {
    status: reasonCodes.length === 0 ? 'valid' : 'invalid', reasonCodes, diagnostics, nativeValidation,
    requirements, scenarios, sourceDigest: digest(root, [...sourcePaths, ...linked]),
    sourcePaths: [...new Set([...sourcePaths, ...linked])].map(file => relativePath(root, file)).sort(),
    validatorVersion: expected.openspec, parserVersion: expected.markdownIt,
  };
}

try {
  const request = await readRequest();
  const result = validate(request, process.argv[2] || '');
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  const code = String(error.message).split(':', 1)[0];
  process.stdout.write(`${JSON.stringify(invalid(code, 'Source validation could not complete.'))}\n`);
}
