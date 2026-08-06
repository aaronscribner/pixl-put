#!/usr/bin/env node
/**
 * rubric.mjs — pure-Node aggregator over `specs/<f>/run.jsonl` files.
 *
 * No LLM, no network. Reads run.jsonl events, joins with optional
 * ground-truth signals piped in, and emits stats JSON.
 *
 * Usage:
 *   node scripts/rubric.mjs aggregate                        # stats for all specs
 *   node scripts/rubric.mjs aggregate --since 7d             # past 7 days only
 *   node scripts/rubric.mjs aggregate --feature 042-add-user # one feature
 *   node scripts/rubric.mjs by-agent                         # roll up by agent
 *   node scripts/rubric.mjs validate                         # schema-check rubric YAMLs
 *
 * Output is always JSON on stdout. The rubric-evaluator agent layers
 * qualitative ground-truth analysis on top of this raw stats output.
 */

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';
import { argv, exit, cwd } from 'node:process';

const SPECS_DIR = 'specs';
const RUBRIC_DIR = 'scripts/rubrics';

function parseArgs(args) {
  const command = args[0];
  const opts = {};
  for (let i = 1; i < args.length; i++) {
    const a = args[i];
    if (a === '--since') opts.since = args[++i];
    else if (a === '--feature') opts.feature = args[++i];
    else if (a === '--agent') opts.agent = args[++i];
    else if (a === '--specs-dir') opts.specsDir = args[++i];
  }
  return { command, opts };
}

function sinceCutoffMs(since) {
  if (!since) return null;
  const m = since.match(/^(\d+)([dhmw])$/);
  if (!m) throw new Error(`invalid --since '${since}'; use Nd|Nh|Nm|Nw`);
  const n = Number(m[1]);
  const unit = { h: 3600e3, d: 86400e3, w: 604800e3, m: 2592000e3 }[m[2]];
  return Date.now() - n * unit;
}

function listFeatureDirs(specsDir) {
  if (!existsSync(specsDir)) return [];
  return readdirSync(specsDir)
    .filter((name) => {
      const p = join(specsDir, name);
      return statSync(p).isDirectory() && existsSync(join(p, 'run.jsonl'));
    })
    .map((name) => ({ name, path: join(specsDir, name) }));
}

function readEvents(featurePath) {
  const file = join(featurePath, 'run.jsonl');
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8')
    .split('\n')
    .filter((l) => l.trim())
    .map((l, idx) => {
      try {
        return JSON.parse(l);
      } catch (e) {
        console.error(`rubric: skipping malformed line ${file}:${idx + 1}`);
        return null;
      }
    })
    .filter(Boolean);
}

function loadAllEvents(opts) {
  const specsDir = opts.specsDir || SPECS_DIR;
  const cutoff = sinceCutoffMs(opts.since);
  const features = opts.feature
    ? [{ name: opts.feature, path: join(specsDir, opts.feature) }]
    : listFeatureDirs(specsDir);
  const events = [];
  for (const f of features) {
    for (const e of readEvents(f.path)) {
      e._feature = f.name;
      const eTs = Date.parse(e.ts);
      if (cutoff && eTs < cutoff) continue;
      if (opts.agent && e.agent !== opts.agent) continue;
      events.push(e);
    }
  }
  return events;
}

function aggregate(events) {
  const total = events.length;
  const byVerdict = {};
  const byAgent = {};
  const byFeature = {};
  const rubricRollup = {};

  for (const e of events) {
    byVerdict[e.verdict] = (byVerdict[e.verdict] || 0) + 1;
    byAgent[e.agent] = (byAgent[e.agent] || 0) + 1;
    byFeature[e._feature] = (byFeature[e._feature] || 0) + 1;
    if (e.rubric && typeof e.rubric === 'object') {
      rubricRollup[e.agent] = rubricRollup[e.agent] || {};
      for (const [criterion, value] of Object.entries(e.rubric)) {
        rubricRollup[e.agent][criterion] = rubricRollup[e.agent][criterion] || { pass: 0, fail: 0, scores: [] };
        if (value === true) rubricRollup[e.agent][criterion].pass++;
        else if (value === false) rubricRollup[e.agent][criterion].fail++;
        else if (typeof value === 'number') rubricRollup[e.agent][criterion].scores.push(value);
      }
    }
  }

  // Compute pass rate + mean score per criterion.
  const rubric = {};
  for (const [agent, criteria] of Object.entries(rubricRollup)) {
    rubric[agent] = {};
    for (const [criterion, c] of Object.entries(criteria)) {
      const n = c.pass + c.fail;
      const entry = { samples: n + c.scores.length };
      if (n > 0) entry.pass_rate = +(c.pass / n).toFixed(3);
      if (c.scores.length > 0) {
        entry.mean_score = +(c.scores.reduce((a, b) => a + b, 0) / c.scores.length).toFixed(3);
      }
      rubric[agent][criterion] = entry;
    }
  }

  return {
    total_events: total,
    features: Object.keys(byFeature).length,
    by_verdict: byVerdict,
    by_agent: byAgent,
    by_feature: byFeature,
    rubric_self_report: rubric,
  };
}

function byAgent(events) {
  const agg = aggregate(events);
  return Object.fromEntries(
    Object.keys(agg.by_agent).sort().map((agent) => {
      const agentEvents = events.filter((e) => e.agent === agent);
      const verdicts = {};
      for (const e of agentEvents) verdicts[e.verdict] = (verdicts[e.verdict] || 0) + 1;
      return [agent, {
        invocations: agentEvents.length,
        unique_features: new Set(agentEvents.map((e) => e._feature)).size,
        by_verdict: verdicts,
        rubric: agg.rubric_self_report[agent] || {},
      }];
    })
  );
}

function validate(opts) {
  const dir = opts.rubricDir || RUBRIC_DIR;
  if (!existsSync(dir)) {
    console.error(`rubric: rubrics directory missing at ${dir}`);
    return { ok: false, missing: dir };
  }
  const files = readdirSync(dir).filter((f) => f.endsWith('.yml'));
  const errors = [];
  for (const f of files) {
    const text = readFileSync(join(dir, f), 'utf8');
    // Very light validation — we don't want a YAML parser dep here.
    if (!/^agent:\s*\S+/m.test(text)) errors.push(`${f}: missing 'agent:' key`);
    if (!/^version:\s*\d+/m.test(text)) errors.push(`${f}: missing 'version:' key`);
    if (!/self_report|ground_truth/m.test(text)) {
      errors.push(`${f}: has neither self_report nor ground_truth`);
    }
  }
  return { ok: errors.length === 0, errors, files: files.length };
}

function main() {
  const { command, opts } = parseArgs(argv.slice(2));
  switch (command) {
    case 'aggregate': {
      const events = loadAllEvents(opts);
      console.log(JSON.stringify(aggregate(events), null, 2));
      break;
    }
    case 'by-agent': {
      const events = loadAllEvents(opts);
      console.log(JSON.stringify(byAgent(events), null, 2));
      break;
    }
    case 'validate': {
      const result = validate(opts);
      console.log(JSON.stringify(result, null, 2));
      if (!result.ok) exit(1);
      break;
    }
    default:
      console.error('usage: rubric.mjs <aggregate|by-agent|validate> [--since 7d] [--feature <slug>] [--agent <name>]');
      exit(2);
  }
}

main();
