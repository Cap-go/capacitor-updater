#!/usr/bin/env node
/*
  Doc generation helper for capacitor-updater
  - Runs @capacitor/docgen to refresh README injections and JSON
  - Builds a polished API.md suitable for the website

  No external deps. Uses Node + the local docgen binary.
*/

const { execFileSync } = require('node:child_process')
const { readFileSync, writeFileSync, existsSync, mkdirSync } = require('node:fs')
const { join } = require('node:path')

const ROOT = process.cwd()
const DOCGEN_BIN = join(ROOT, 'node_modules', '.bin', 'docgen')
const DIST_DIR = join(ROOT, 'dist')
const DOCS_JSON = join(DIST_DIR, 'docs.json')
const README = join(ROOT, 'README.md')
const API_MD = join(ROOT, 'api.md')

function log(step, msg) {
  const map = {
    start: '🔧',
    ok: '✅',
    info: 'ℹ️ ',
    warn: '⚠️ ',
  }
  const icon = map[step] || '•'
  process.stdout.write(`${icon} ${msg}\n`)
}

function runDocgen() {
  if (!existsSync(DIST_DIR)) mkdirSync(DIST_DIR)
  log('start', 'Generating docs via @capacitor/docgen…')
  try {
    execFileSync(
      DOCGEN_BIN,
      [
        '--api',
        'CapacitorUpdaterPlugin',
        '--output-readme',
        README,
        '--output-json',
        DOCS_JSON,
      ],
      { stdio: 'inherit' },
    )
    log('ok', 'Docgen completed (README + JSON refreshed)')
  } catch (e) {
    log('warn', 'Docgen failed via binary, attempting fallback CLI name…')
    // Fallback: try calling `docgen` if bin resolution fails in some environments
    execFileSync('docgen', [
      '--api',
      'CapacitorUpdaterPlugin',
      '--output-readme',
      README,
      '--output-json',
      DOCS_JSON,
    ], { stdio: 'inherit' })
    log('ok', 'Docgen completed with fallback')
  }
}

function loadDocsJson() {
  if (!existsSync(DOCS_JSON)) {
    throw new Error('dist/docs.json not found. Ensure docgen step succeeded.')
  }
  return JSON.parse(readFileSync(DOCS_JSON, 'utf8'))
}

function stripDocgenBlocks(md) {
  // Remove any existing docgen sections to avoid duplication when rebuilding pieces
  const removeBlock = (startTag) => {
    const endTag = startTag.replace('<', '</')
    const re = new RegExp(`${startTag}[\s\S]*?${endTag}`, 'g')
    return (s) => s.replace(re, `${startTag}\n${endTag}`)
  }
  md = removeBlock('<docgen-config>')(md)
  md = removeBlock('<docgen-index>')(md)
  md = removeBlock('<docgen-api>')(md)
  return md
}

function renderFrontmatterPreserved(existing) {
  if (!existing) return { frontmatter: '', rest: '' }
  if (!existing.trim().startsWith('---')) return { frontmatter: '', rest: existing }
  const parts = existing.split('\n')
  // find second ---
  let end = -1
  for (let i = 1; i < parts.length; i++) {
    if (parts[i].trim() === '---') { end = i; break }
  }
  if (end === -1) return { frontmatter: '', rest: existing }
  const frontmatter = parts.slice(0, end + 1).join('\n')
  const rest = parts.slice(end + 1).join('\n').replace(/^\n+/, '')
  return { frontmatter, rest }
}

function mdCode(code, lang = '') {
  return '```' + lang + '\n' + code + '\n```\n\n'
}

function mdTable(headers, rows) {
  const head = '| ' + headers.join(' | ') + ' |\n'
  const sep = '| ' + headers.map(() => '---').join(' | ') + ' |\n'
  const body = rows.map(r => '| ' + headers.map(h => r[h] ?? '').join(' | ') + ' |').join('\n') + (rows.length ? '\n' : '')
  return head + sep + body + '\n'
}

function escapeMd(s = '') {
  return String(s).replace(/\|/g, '\\|')
}

function renderConfig(pluginConfigs) {
  if (!pluginConfigs || !pluginConfigs.length) return ''
  const cfg = pluginConfigs[0]
  let out = '# Updater Plugin Config\n\n'
  out += '<docgen-config>\n'
  out += '<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->\n\n'
  out += `${cfg.name} can be configured with these options:\n\n`
  const headers = ['Prop', 'Type', 'Description', 'Default', 'Since']
  const rows = cfg.properties.map(p => {
    const def = p.tags?.find(t => t.name === 'default')?.text || ''
    const since = p.tags?.find(t => t.name === 'since')?.text || ''
    const doc = (p.docs || '').replace(/\n+/g, ' ').trim()
    return {
      Prop: `**\`${p.name}\`**`,
      Type: `\`${p.type.replace(/ \| undefined$/, '')}\``,
      Description: escapeMd(doc),
      Default: def ? `\`${def}\`` : '',
      Since: since || '',
    }
  })
  out += mdTable(headers, rows)
  out += '\n</docgen-config>\n\n'
  return out
}

function renderMethods(api) {
  const methods = api.methods || []
  if (!methods.length) return ''
  let out = '## API Reference\n\n'
  out += '<docgen-index>\n'
  out += '<!--Auto-generated, do not edit by hand-->\n\n'
  out += methods.map(m => {
    let label = m.name
    if (m.name === 'addListener') {
      const match = m.signature && m.signature.match(/\(eventName: '([^']+)'/)
      if (match) label = `addListener('${match[1]}')`
    } else if (!m.signature?.includes('(')) {
      label = `${m.name}()`
    }
    return `- [\`${label}\`](#${m.slug})`
  }).join('\n') + '\n\n'
  out += '</docgen-index>\n\n'

  out += '<docgen-api>\n'
  out += '<!--Auto-generated, do not edit by hand-->\n\n'
  for (const m of methods) {
    let header = m.name
    if (m.name === 'addListener') {
      const match = m.signature && m.signature.match(/\(eventName: '([^']+)'/)
      if (match) header = `addListener('${match[1]}')`
    }
    out += `### ${header}\n\n`
    if (m.signature) out += mdCode(`${m.name}${m.signature.replace(/^\w+/, '')}`, 'typescript')
    if (m.docs) out += m.docs + '\n\n'

    if (m.parameters && m.parameters.length) {
      out += '**Parameters**\n\n'
      const rows = m.parameters.map(p => ({
        Name: `\`${p.name}\``,
        Type: `\`${p.type}\``,
        Description: escapeMd(p.docs || ''),
      }))
      out += mdTable(['Name', 'Type', 'Description'], rows)
    }

    // returns
    const returnsTag = (m.tags || []).find(t => t.name === 'returns')
    if (m.returns || returnsTag?.text) {
      out += '**Returns**\n\n'
      const desc = returnsTag?.text ? ' — ' + returnsTag.text : ''
      out += `\`${m.returns || 'void'}\`${desc}\n\n`
    }

    // since
    const sinceTag = (m.tags || []).find(t => t.name === 'since')
    if (sinceTag?.text) out += `**Since:** ${sinceTag.text}\n\n`

    // throws
    const throwsTag = (m.tags || []).find(t => t.name === 'throws')
    if (throwsTag?.text) out += `**Throws:** ${throwsTag.text}\n\n`

    // examples (can be multiple)
    const examples = (m.tags || []).filter(t => t.name === 'example')
    for (const ex of examples) {
      out += '**Example**\n\n'
      out += mdCode(ex.text.trim(), 'ts')
    }

    out += '\n--------------------\n\n\n'
  }
  out += '</docgen-api>\n'
  return out
}

function buildApiMd(docsJson) {
  const existing = existsSync(API_MD) ? readFileSync(API_MD, 'utf8') : ''
  const { frontmatter } = renderFrontmatterPreserved(existing)
  const header = frontmatter || `---\n` +
    `title: "Functions and settings"\n` +
    `description: "All available method and settings of the plugin"\n` +
    `sidebar:\n  order: 2\n` +
    `---\n\n`

  let body = ''
  body += renderConfig(docsJson.pluginConfigs)
  body += renderMethods(docsJson.api)

  const headerWithGap = header.endsWith('\n\n') ? header : header.endsWith('\n') ? header + '\n' : header + '\n\n'
  const content = `${headerWithGap}${body}`
  writeFileSync(API_MD, content)
  log('ok', 'API.md generated')
}

function tweakReadmeHeadings() {
  // Adjust README heading levels inside docgen api for nicer scanability
  if (!existsSync(README)) return
  let md = readFileSync(README, 'utf8')
  // Within <docgen-api>, demote ### to #### to keep README compact
  md = md.replace(/<docgen-api>[\s\S]*?<\/docgen-api>/, (block) => {
    return block.replace(/### /g, '#### ')
  })
  // Within <docgen-index>, ensure bullet anchors are compact
  md = md.replace(/<docgen-index>[\s\S]*?<\/docgen-index>/, (block) => {
    // Insert a small lead-in line
    const lines = block.split('\n')
    if (!lines[1]?.includes('Auto-generated')) {
      lines.splice(1, 0, '<!--Auto-generated, compact index-->')
    }
    return lines.join('\n')
  })
  writeFileSync(README, md)
  log('ok', 'README polished (headings + index)')
}

function main() {
  log('info', 'Capacitor Updater — Docs Generator')
  runDocgen()
  const docsJson = loadDocsJson()
  buildApiMd(docsJson)
  tweakReadmeHeadings()
  log('ok', 'All docs updated ✨')
}

main()
