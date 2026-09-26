import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { duplicatePresentation } from '../src/duplicate_status.js';

test('duplicate check-in displays the existing attendance decision', () => {
  const email = 'student@fpt.edu.vn';
  const present = duplicatePresentation('present', email);
  const absent = duplicatePresentation('absent', email);
  const excused = duplicatePresentation('excused', email);

  assert.equal(present.kind, 'success');
  assert.match(present.detail, /có mặt/);
  assert.equal(absent.kind, 'warning');
  assert.match(absent.detail, /liên hệ giảng viên/);
  assert.equal(excused.kind, 'info');
  assert.match(excused.detail, /có phép/);
});
