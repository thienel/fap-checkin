// Usage: node tool/teacher_access.cjs <email> [--grant]
//        node tool/teacher_access.cjs --rules
// Uses the currently selected Firebase CLI account. No user password is needed.
const fs = require('node:fs');
const path = require('node:path');
const {execSync} = require('node:child_process');
const {createHash} = require('node:crypto');

async function main() {
  const [email, action] = process.argv.slice(2);
  if (email !== '--rules' && (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
      (action !== undefined && action !== '--grant'))) {
    throw new Error('Usage: node tool/teacher_access.cjs <email> [--grant] | --rules');
  }

  const root = path.resolve(__dirname, '..');
  const project = JSON.parse(fs.readFileSync(path.join(root, '.firebaserc'), 'utf8'))
    .projects.default;
  const desktopProject = JSON.parse(fs.readFileSync(
    path.join(root, 'firebase.desktop.json'), 'utf8')).FIREBASE_PROJECT_ID;
  if (!project || project !== desktopProject) {
    throw new Error('Firebase CLI and desktop project IDs do not match.');
  }

  const globalModules = execSync(`${process.platform === 'win32' ? 'npm.cmd' : 'npm'} root -g`, {
    encoding: 'utf8', windowsHide: true,
  }).trim();
  const auth = require(path.join(globalModules, 'firebase-tools', 'lib', 'auth.js'));
  const account = auth.getProjectDefaultAccount(root);
  if (!account?.tokens?.refresh_token) {
    throw new Error('Firebase CLI is not signed in. Run firebase login first.');
  }
  const {access_token: token} = await auth.getAccessToken(account.tokens.refresh_token, []);
  if (!token) throw new Error('Firebase CLI did not provide an access token.');

  async function request(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok && response.status !== 404) {
      throw new Error(`Firebase API ${response.status}: ${body.error?.message || response.statusText}`);
    }
    return {status: response.status, body};
  }

  if (email === '--rules') {
    const releases = await request(
      `https://firebaserules.googleapis.com/v1/projects/${encodeURIComponent(project)}/releases`,
    );
    const release = (releases.body.releases || []).find((item) =>
      item.name.endsWith('/releases/cloud.firestore'));
    if (!release?.rulesetName) throw new Error('No deployed Cloud Firestore rules release found.');
    const ruleset = await request(
      `https://firebaserules.googleapis.com/v1/${release.rulesetName}`,
    );
    const remote = ruleset.body.source?.files?.map((file) => file.content).join('\n');
    if (!remote) throw new Error('Deployed rules source is empty.');
    const local = fs.readFileSync(path.join(root, 'firestore.rules'), 'utf8');
    const hash = (source) => createHash('sha256')
      .update(source.replace(/\r\n/g, '\n').trim()).digest('hex');
    console.log(JSON.stringify({project, release: release.name,
      deployedAt: release.updateTime, matchesLocal: hash(remote) === hash(local),
      remoteHash: hash(remote), localHash: hash(local)}));
    return;
  }

  const lookup = await request(
    `https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(project)}/accounts:lookup`,
    {method: 'POST', body: JSON.stringify({email: [email.toLowerCase()]})},
  );
  const users = (lookup.body.users || []).filter((user) =>
    user.email?.toLowerCase() === email.toLowerCase());
  if (users.length !== 1) {
    throw new Error(`Expected one Firebase Auth account for ${email}; found ${users.length}.`);
  }
  const user = users[0];
  if (user.disabled) throw new Error('The Firebase Auth account is disabled.');
  const uid = user.localId;
  if (!uid || uid.includes('/')) throw new Error('Firebase Auth returned an invalid UID.');

  const documentUrl = `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(project)}` +
    `/databases/(default)/documents/teachers/${encodeURIComponent(uid)}`;
  const before = await request(documentUrl);
  const active = before.status === 200 && before.body.fields?.active?.booleanValue === true;
  if (action !== '--grant' || active) {
    console.log(JSON.stringify({project, email: user.email, uid,
      teacherDocumentExists: before.status === 200, active}));
    return;
  }

  const precondition = before.status === 404
    ? 'currentDocument.exists=false'
    : `currentDocument.updateTime=${encodeURIComponent(before.body.updateTime)}`;
  const patchUrl = `${documentUrl}?updateMask.fieldPaths=active&${precondition}`;
  await request(patchUrl, {
    method: 'PATCH',
    body: JSON.stringify({fields: {active: {booleanValue: true}}}),
  });
  const after = await request(documentUrl);
  if (after.body.fields?.active?.booleanValue !== true) {
    throw new Error('Teacher document did not verify as active after the update.');
  }
  console.log(JSON.stringify({project, email: user.email, uid,
    teacherDocumentExists: true, active: true, changed: true}));
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
