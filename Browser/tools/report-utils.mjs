import {engineFromUserAgent} from '../src/diagnostics.js';

// Only whitelisted engine names and normalized identifiers enter local paths.
// The submitted report's title, URL and filenames never become path segments.
export function reportIdentity(value,stamp,nonce) {
  const environment=value?.environment||{};
  const inferred=engineFromUserAgent(environment.userAgent||'');
  const engine=['chromium','gecko','webkit'].includes(environment.engine)?environment.engine:inferred;
  const raw=value?.build?.sourceDigest;
  const build=typeof raw==='string'&&/^[a-f0-9]{64}$/.test(raw)?raw.slice(0,16):'unversioned';
  if(!/^[0-9TZ-]+$/.test(stamp)||!/^[a-f0-9-]+$/.test(nonce))throw new Error('Invalid local report identifier');
  return {engine,filename:`${build}-${stamp}-${nonce}.json`};
}
