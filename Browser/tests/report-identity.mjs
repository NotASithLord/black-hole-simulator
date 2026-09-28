import assert from 'node:assert/strict';
import {reportIdentity} from '../tools/report-utils.mjs';
const stamp='2026-09-27T12-00-00-000Z',nonce='a1b2-1234';
assert.deepEqual(reportIdentity({environment:{engine:'gecko'},build:{sourceDigest:'a'.repeat(64)}},stamp,nonce),
  {engine:'gecko',filename:`${'a'.repeat(16)}-${stamp}-${nonce}.json`});
assert.equal(reportIdentity({environment:{engine:'../../elsewhere',userAgent:'Chrome/150.0'}},stamp,nonce).engine,'chromium');
assert.ok(reportIdentity({build:{sourceDigest:'../../etc'}},stamp,nonce).filename.startsWith('unversioned-'));
assert.throws(()=>reportIdentity({},'../../other',nonce));
assert.throws(()=>reportIdentity({},stamp,'../other'));
console.log('PASS Report archive retains separate engine/build identities and rejects path injection');
