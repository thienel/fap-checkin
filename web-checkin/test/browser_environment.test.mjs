import test from 'node:test';
import assert from 'node:assert/strict';
import { signInBrowserProblem } from '../src/browser_environment.js';

function storage() {
  const values = new Map();
  return {
    setItem: (key, value) => values.set(key, value),
    getItem: (key) => values.get(key) ?? null,
    removeItem: (key) => values.delete(key),
    values,
  };
}

for (const agent of [
  'Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 Zalo/24.01',
  'Mozilla/5.0 (iPhone) [FBAN/FBIOS;FBAV/500.0]',
  'Mozilla/5.0 (Linux; Android 14; Pixel 8; wv) AppleWebKit/537.36',
]) {
  test(`embedded browser is stopped before accessing auth storage: ${agent}`, () => {
    assert.equal(signInBrowserProblem(agent, () => { throw new Error('must not run'); }), 'embedded');
  });
}

for (const agent of [
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1',
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36',
]) {
  test(`standalone browser may sign in and existing QR is preserved: ${agent}`, () => {
    const store = storage();
    store.setItem('attendanceQrToken', 'existing-qr');
    assert.equal(signInBrowserProblem(agent, () => store), null);
    assert.deepEqual([...store.values], [['attendanceQrToken', 'existing-qr']]);
  });
}

test('blocked storage getter is handled before Firebase initialization', () => {
  assert.equal(signInBrowserProblem('Safari', () => { throw new Error('SecurityError'); }), 'storage');
});

test('storage silently discarding writes cannot start sign-in', () => {
  assert.equal(signInBrowserProblem('Chrome', () => ({
    setItem() {}, getItem() { return null; }, removeItem() {},
  })), 'storage');
});
