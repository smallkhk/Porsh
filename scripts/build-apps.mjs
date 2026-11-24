// Builds the web bundles for the two native iOS apps.
//   node scripts/build-apps.mjs [viewer|key|all]
// Env:
//   APEX_DOMAIN  your VPS domain, e.g. apex.example.com (needed for the apps to find each other)
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const which = process.argv[2] || 'all';
const domain = (process.env.APEX_DOMAIN || '').replace(/^https?:\/\//, '').replace(/\/.*$/, '');
if (!domain) console.warn('! APEX_DOMAIN not set: the apps will fall back to the public PeerJS broker.');

const APPS = {
  viewer: { entry: 'index.html', id: 'app.apex9r.viewer', name: 'APEX 9R' },
  key: { entry: 'remote.html', id: 'app.apex9r.key', name: 'APEX Key' },
};

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const e of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, e.name), d = path.join(dst, e.name);
    e.isDirectory() ? copyDir(s, d) : fs.copyFileSync(s, d);
  }
}

for (const [name, app] of Object.entries(APPS)) {
  if (which !== 'all' && which !== name) continue;
  const dir = path.join(ROOT, 'apps', name), www = path.join(dir, 'www');
  fs.rmSync(www, { recursive: true, force: true });
  for (const d of ['css', 'js', 'icons']) copyDir(path.join(ROOT, d), path.join(www, d));
  // Capacitor always boots index.html
  fs.copyFileSync(path.join(ROOT, app.entry), path.join(www, 'index.html'));
  if (name === 'key') fs.copyFileSync(path.join(ROOT, 'remote.html'), path.join(www, 'remote.html'));
  const cfg = domain ? { relay: `wss://${domain}/relay`, publicUrl: `https://${domain}/`, native: name } : { native: name };
  fs.writeFileSync(path.join(www, 'js', 'config.js'), `window.APEX_CONFIG = ${JSON.stringify(cfg)};\n`);
  fs.writeFileSync(path.join(dir, 'capacitor.config.json'), JSON.stringify({
    appId: app.id, appName: app.name, webDir: 'www',
    backgroundColor: name === 'viewer' ? '#07080b' : '#0a0b10',
    ios: { contentInset: 'never', scrollEnabled: name === 'key', allowsLinkPreview: false },
  }, null, 2) + '\n');
  // Capacitor reads plugins from this package.json; modules resolve from the repo root.
  const dev = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).devDependencies;
  const deps = { '@capacitor/core': dev['@capacitor/core'], '@capacitor/ios': dev['@capacitor/ios'] };
  if (name === 'key') deps['@capacitor/haptics'] = dev['@capacitor/haptics'];
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name: `apex9r-${name}`, private: true, dependencies: deps }, null, 2) + '\n');
  console.log(`✓ ${name}: apps/${name}/www  (${app.id})${domain ? '  relay wss://' + domain + '/relay' : ''}`);
}
