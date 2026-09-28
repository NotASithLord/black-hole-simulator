import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';

const inputBytes=await readFile(new URL('../../Tests/physics_cases.json',import.meta.url));
const input=JSON.parse(inputBytes);
const reference=JSON.parse(await readFile(new URL('./fixtures/native-reference.json',import.meta.url),'utf8'));
assert.equal(reference.schema,1);
assert.equal(reference.inputSHA256,createHash('sha256').update(inputBytes).digest('hex'));
assert.equal(input.cases.length,177);
assert.equal(reference.cases.length,177);
const ids=new Set(reference.cases.map(item=>item.id));
assert.equal(ids.size,177);
assert.ok(input.cases.every(item=>ids.has(item.id)));
for(const row of reference.cases) {
  assert.deepEqual(Object.keys(row).sort(),['id','result']);
  assert.equal(row.result.length,16);
  assert.ok(row.result.every(Number.isFinite));
  assert.ok(Number.isInteger(row.result[4]));
}
console.log('PASS Tracked native fixture contains all 177 unique finite ray results without machine metadata');
