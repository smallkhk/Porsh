// Customises a generated Capacitor iOS project:  node scripts/patch-ios.mjs <viewer|key>
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const name = process.argv[2];
if (!['viewer', 'key'].includes(name)) { console.error('usage: patch-ios.mjs viewer|key'); process.exit(1); }
const app = path.join(ROOT, 'apps', name, 'ios', 'App', 'App');

// 1) icon (single 1024 universal icon)
fs.copyFileSync(path.join(ROOT, 'icons', `${name}-1024.png`), path.join(app, 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-512@2x.png'));

// 2) Info.plist
const plistPath = path.join(app, 'Info.plist');
let plist = fs.readFileSync(plistPath, 'utf8');
const arr = (items) => `<array>\n${items.map(i => `\t\t<string>${i}</string>`).join('\n')}\n\t</array>`;
const setKey = (key, valueXml) => {
  const re = new RegExp(`\\t<key>${key}</key>\\s*(<array>[\\s\\S]*?</array>|<[a-z]+/>|<string>[\\s\\S]*?</string>)`);
  const entry = `\t<key>${key}</key>\n\t${valueXml}`;
  plist = re.test(plist) ? plist.replace(re, entry) : plist.replace(/<\/dict>\s*<\/plist>\s*$/, `${entry}\n</dict>\n</plist>\n`);
};
const L = ['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'];
const P = ['UIInterfaceOrientationPortrait'];
if (name === 'viewer') {
  setKey('UISupportedInterfaceOrientations', arr(L));
  setKey('UISupportedInterfaceOrientations~ipad', arr(L));
  setKey('UIStatusBarHidden', '<true/>');
  setKey('UIViewControllerBasedStatusBarAppearance', '<false/>');
} else {
  setKey('UISupportedInterfaceOrientations', arr(P));
  setKey('UISupportedInterfaceOrientations~ipad', arr(P));
  setKey('NSCameraUsageDescription', '<string>Scan the QR code on the showroom screen to pair your key.</string>');
  setKey('UIStatusBarStyle', '<string>UIStatusBarStyleLightContent</string>');
}
setKey('UIRequiresFullScreen', '<true/>');
setKey('ITSAppUsesNonExemptEncryption', '<false/>');
fs.writeFileSync(plistPath, plist);
console.log(`✓ patched ${name} (icon, Info.plist)`);
