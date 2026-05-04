const fs = require('fs');
const path = require('path');

const filePath = path.join(process.cwd(), 'app', 'linked-accounts.tsx');

if (!fs.existsSync(filePath)) {
  console.error('File not found:', filePath);
  process.exit(1);
}

let content = fs.readFileSync(filePath, 'utf8');

const target = `
          <View style={styles.accountHeader}>
            <Text style={styles.accountName}>{displayName}</Text>
            <View style={styles.roleBadge}>
              <Text style={styles.roleBadgeText}>{isOwner ? 'عميلك' : 'أنت عميل عنده'}</Text>
            </View>
          </View>
`;

const replacement = `
          <View style={styles.accountHeader}>
            <Text style={styles.accountName}>{displayName}</Text>
            {isOwner ? (
              <View style={styles.roleBadge}>
                <Text style={styles.roleBadgeText}>عميلك</Text>
              </View>
            ) : null}
          </View>
`;

if (!content.includes(target)) {
  console.error('Patch failed: target block not found in app/linked-accounts.tsx');
  process.exit(1);
}

const backupPath = filePath + '.backup-remove-anta-ameel-' + Date.now();
fs.copyFileSync(filePath, backupPath);
console.log('Backup created:', backupPath);

content = content.replace(target, replacement);
fs.writeFileSync(filePath, content, 'utf8');

console.log('Updated:', filePath);
console.log('Done successfully.');