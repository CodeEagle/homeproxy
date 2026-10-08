'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

test('quota monitor shell behavior', () => {
  const script = path.join(__dirname, 'quota_monitor.test.sh');
  const result = spawnSync('/bin/sh', [script], { encoding: 'utf8' });
  assert.equal(
    result.status,
    0,
    `${result.stdout || ''}${result.stderr || ''}`,
  );
  assert.match(result.stdout || '', /PASS: quota monitor shell behavior/);
});
