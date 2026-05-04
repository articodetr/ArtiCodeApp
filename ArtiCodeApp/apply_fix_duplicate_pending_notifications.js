
const fs = require('fs');
const path = require('path');

function assertFile(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`File not found: ${filePath}`);
  }
}

function backupFile(filePath) {
  const backupPath = `${filePath}.backup-fix-pending-notification-duplicates-${Date.now()}`;
  fs.copyFileSync(filePath, backupPath);
  return backupPath;
}

function replaceOrThrow(source, pattern, replacement, label) {
  if (!pattern.test(source)) {
    throw new Error(`Could not find target block for: ${label}`);
  }
  return source.replace(pattern, replacement);
}

function patchNotificationService(projectRoot) {
  const filePath = path.join(projectRoot, 'services', 'notificationService.ts');
  assertFile(filePath);
  const backupPath = backupFile(filePath);
  let content = fs.readFileSync(filePath, 'utf8');

  content = replaceOrThrow(
    content,
    /customer_name:\s*item\.customer_name\s*\|\|\s*movement\?\.customer\?\.name\s*\|\|\s*null,/,
    "customer_name: movement?.customer?.name || item.customer_name || null,",
    'services/notificationService.ts -> prefer movement customer name',
  );

  content = replaceOrThrow(
    content,
    /function normalizeNotification\(item: MovementNotification\): MovementNotification \{[\s\S]*?\n\}/,
    (match) => match + "\n\nfunction buildPendingApprovalDedupeKey(item: MovementNotification) {\n  const rawStatus = getNotificationRawStatus(item);\n\n  if (item.notification_type !== 'approval_needed' || rawStatus !== 'pending' || !item.movement_id) {\n    return null;\n  }\n\n  return `${item.user_id || 'unknown'}::${item.movement_id}::${rawStatus}`;\n}\n\nfunction choosePreferredPendingApprovalNotification(\n  current: MovementNotification,\n  candidate: MovementNotification,\n): MovementNotification {\n  const currentLooksCreatorOwned = sameId(current.user_id, current.sender_user_id) || current.action_required === false;\n  const candidateLooksCreatorOwned = sameId(candidate.user_id, candidate.sender_user_id) || candidate.action_required === false;\n\n  if (candidateLooksCreatorOwned && !currentLooksCreatorOwned) {\n    return candidate;\n  }\n\n  if (candidate.action_required === true && current.action_required !== true) {\n    return candidate;\n  }\n\n  const currentTime = Date.parse(current.created_at || '') || 0;\n  const candidateTime = Date.parse(candidate.created_at || '') || 0;\n\n  return candidateTime > currentTime ? candidate : current;\n}\n\nfunction dedupePendingApprovalNotifications(notifications: MovementNotification[]) {\n  const byKey = new Map();\n  const ordered = [];\n\n  for (const item of notifications) {\n    const key = buildPendingApprovalDedupeKey(item);\n\n    if (!key) {\n      ordered.push(item);\n      continue;\n    }\n\n    const existing = byKey.get(key);\n    if (!existing) {\n      byKey.set(key, item);\n      ordered.push(item);\n      continue;\n    }\n\n    const preferred = choosePreferredPendingApprovalNotification(existing, item);\n    if (preferred !== existing) {\n      byKey.set(key, preferred);\n      const index = ordered.indexOf(existing);\n      if (index >= 0) {\n        ordered[index] = preferred;\n      }\n    }\n  }\n\n  return ordered;\n}",
    'services/notificationService.ts -> insert dedupe helpers after normalizeNotification',
  )

  content = replaceOrThrow(
    content,
    /subtitle = createdByCurrentUser \? `بانتظار موافقة \$\{customerName\}\.` : 'بانتظار الموافقة\.';/,
    [
      "if (createdByCurrentUser) {",
      "    subtitle = `أنت قيدت على ${customerName} مبلغ ${amountSentenceText} وبانتظار موافقته.`;",
      "  } else {",
      "    subtitle = `${actorName} قيد عليك مبلغ ${amountSentenceText} وبانتظار موافقتك.`;",
      "  }",
    ].join('\n  '),
    'services/notificationService.ts -> pending subtitle text',
  );

  content = replaceOrThrow(
    content,
    /return \(\(\(data \|\| \[\]\) as MovementNotification\[\]\)\.map\(normalizeNotification\);\s*\}/,
    "return dedupePendingApprovalNotifications(((data || []) as MovementNotification[]).map(normalizeNotification));\n\n}",
    'services/notificationService.ts -> getGeneralNotifications return',
  );

  content = replaceOrThrow(
    content,
    /return \(\(\(data \|\| \[\]\) as MovementNotification\[\]\)\.map\(normalizeNotification\);\s*\n\n\}/,
    "return dedupePendingApprovalNotifications(((data || []) as MovementNotification[]).map(normalizeNotification));\n\n}",
    'services/notificationService.ts -> getCustomerNotifications return',
  );

  // The previous two replacements may both target same pattern depending on spacing; ensure at least one customer return was changed.
  const occurrences = (content.match(/dedupePendingApprovalNotifications\(\(\(data \|\| \[\]\) as MovementNotification\[\]\)\.map\(normalizeNotification\)\)/g) || []).length;
  if (occurrences < 2) {
    content = content.replace(
      /return \(\(\(data \|\| \[\]\) as MovementNotification\[\]\)\.map\(normalizeNotification\);/g,
      "return dedupePendingApprovalNotifications(((data || []) as MovementNotification[]).map(normalizeNotification));"
    );
  }

  fs.writeFileSync(filePath, content, 'utf8');
  return { filePath, backupPath };
}

function main() {
  const projectRoot = process.cwd();
  const results = [];
  results.push(patchNotificationService(projectRoot));

  console.log('Done successfully.');
  for (const result of results) {
    console.log(`Patched: ${result.filePath}`);
    console.log(`Backup : ${result.backupPath}`);
  }
  console.log('Next steps:');
  console.log('1) Run the cleanup SQL in Supabase (optional but recommended)');
  console.log('2) npm run typecheck');
  console.log('3) npx expo start -c');
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
}
