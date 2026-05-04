const fs = require('fs');
const path = require('path');

const root = process.cwd();
const filePath = path.join(root, 'app', 'linked-accounts.tsx');
const backupDir = path.join(root, '.remove-linked-account-badge-backup');

function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function backupFile(targetPath) {
  ensureDir(backupDir);
  const backupPath = path.join(
    backupDir,
    `${path.basename(targetPath)}.${Date.now()}.bak`
  );
  fs.copyFileSync(targetPath, backupPath);
  console.log(`Backup created: ${backupPath}`);
}

if (!fs.existsSync(filePath)) {
  console.error(`File not found: ${filePath}`);
  process.exit(1);
}

let content = fs.readFileSync(filePath, 'utf8');
const original = content;

const oldBlock = `            <View style={styles.roleBadge}>\n              <Text style={styles.roleBadgeText}>{isOwner ? 'عميلك' : 'أنت عميل عنده'}</Text>\n            </View>`;

const newBlock = `            {isOwner ? (\n              <View style={styles.roleBadge}>\n                <Text style={styles.roleBadgeText}>عميلك</Text>\n              </View>\n            ) : null}`;

if (!content.includes(oldBlock)) {
  console.error('Patch failed: target block not found in app/linked-accounts.tsx');
  process.exit(1);
}

content = content.replace(oldBlock, newBlock);

if (content === original) {
  console.error('No changes were made.');
  process.exit(1);
}

backupFile(filePath);
fs.writeFileSync(filePath, content, 'utf8');
console.log(`Updated: ${filePath}`);
console.log('Done successfully.');
console.log('Next steps:');
console.log('1) npm run typecheck');
console.log('2) git add app/linked-accounts.tsx');
console.log('3) git commit -m "Remove non-owner linked account badge text"');
