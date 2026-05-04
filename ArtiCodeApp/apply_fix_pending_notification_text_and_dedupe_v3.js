
const fs = require('fs');
const path = require('path');

function assertFile(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`File not found: ${filePath}`);
  }
}

function backupFile(filePath) {
  const backupPath = `${filePath}.backup-fix-pending-notification-text-and-dedupe-v3-${Date.now()}`;
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

  if (!/function getNotificationDedupScore\(item: MovementNotification\)/.test(content)) {
    content = replaceOrThrow(
      content,
      /function normalizeNotification\(item: MovementNotification\): MovementNotification \{[\s\S]*?return \{[\s\S]*?\n\}\n/,
      (match) => match + `
function getNotificationDedupScore(item: MovementNotification) {
  let score = 0;

  if (item.movement?.customer?.name) score += 10;
  if (item.customer_name) score += 5;
  if (item.action_required === false) score += 2;
  if (item.message) score += 1;
  if (item.title) score += 1;

  return score;
}

function dedupeMovementNotifications(items: MovementNotification[]): MovementNotification[] {
  const output = new Map<string, MovementNotification>();

  for (const rawItem of items) {
    const item = normalizeNotification(rawItem);
    const rawStatus = getNotificationRawStatus(item);
    const key = item.movement_id
      ? [item.user_id || '', item.movement_id, rawStatus || item.notification_type || 'info'].join('::')
      : item.id;

    const existing = output.get(key);
    if (!existing) {
      output.set(key, item);
      continue;
    }

    const currentScore = getNotificationDedupScore(item);
    const existingScore = getNotificationDedupScore(existing);

    if (currentScore > existingScore) {
      output.set(key, item);
    }
  }

  return Array.from(output.values());
}

`,
      'services/notificationService.ts -> add dedupe helpers',
    );
  }

  content = replaceOrThrow(
    content,
    /} else if \(pending\) \{[\s\S]*?visualState = 'pending';\s*\}/,
    `} else if (pending) {
  if (createdByCurrentUser) {
    subtitle = customerName
      ? \`أنت قيدت على \${customerName}\${amountSentenceText ? \` مبلغ \${amountSentenceText}\` : ''} وبانتظار موافقته.\`
      : 'أنت أضفت هذه الحركة وهي بانتظار موافقة الطرف الآخر.';
  } else {
    subtitle = actorName
      ? \`\${actorName} قيد عليك\${amountSentenceText ? \` مبلغ \${amountSentenceText}\` : ''} وبانتظار موافقتك.\`
      : 'هذه الحركة بانتظار موافقتك قبل أن تدخل في الإجماليات.';
  }

  statusText = 'معلقة';

  statusColor = '#B45309';

  statusBg = '#FEF3C7';

  rowBorderColor = '#FBBF24';

  rowBg = '#FFFBEB';

  visualState = 'pending';
}`,
    'services/notificationService.ts -> pending subtitle',
  );

  content = replaceOrThrow(
    content,
    /return \(\(data \|\| \[\]\) as MovementNotification\[\]\)\.map\(normalizeNotification\);/g,
    "return dedupeMovementNotifications((data || []) as MovementNotification[]);",
    'services/notificationService.ts -> dedupe returned notifications',
  );

  fs.writeFileSync(filePath, content, 'utf8');
  return { filePath, backupPath };
}

function patchCustomerNotifications(projectRoot) {
  const filePath = path.join(projectRoot, 'app', 'customer-notifications.tsx');
  assertFile(filePath);
  const backupPath = backupFile(filePath);
  let content = fs.readFileSync(filePath, 'utf8');

  if (!/function dedupeAndFixCustomerNotifications\(/.test(content)) {
    content = replaceOrThrow(
      content,
      /function searchNotificationsLocally\([\s\S]*?return notifications\.filter\(\(item\) => getNotificationSearchText\(item\)\.includes\(query\)\);\s*\}/,
      (match) => match + `

function dedupeAndFixCustomerNotifications(
  notifications: MovementNotification[],
  forcedCustomerName?: string,
) {
  const cleanedForcedCustomerName = String(forcedCustomerName || '').trim();
  const output = new Map<string, MovementNotification>();

  for (const rawItem of notifications) {
    const anyItem = rawItem as any;
    const movement = anyItem.movement || null;

    const patchedItem: MovementNotification = {
      ...rawItem,
      customer_name: cleanedForcedCustomerName || rawItem.customer_name,
      movement: movement
        ? {
            ...movement,
            customer: {
              ...(movement.customer || {}),
              name:
                cleanedForcedCustomerName ||
                movement.customer?.name ||
                rawItem.customer_name ||
                null,
            },
          }
        : movement,
    };

    const rawStatus = getNotificationRawStatus(patchedItem);
    const key = patchedItem.movement_id
      ? [patchedItem.movement_id, rawStatus || anyItem.notification_type || 'info'].join('::')
      : patchedItem.id;

    if (!output.has(key)) {
      output.set(key, patchedItem);
      continue;
    }

    const existing = output.get(key)!;
    const existingAny = existing as any;

    const currentScore =
      (patchedItem.customer_name ? 10 : 0) +
      (patchedItem.action_required === false ? 2 : 0) +
      (patchedItem.message ? 1 : 0);

    const existingScore =
      (existing.customer_name ? 10 : 0) +
      (existing.action_required === false ? 2 : 0) +
      (existingAny.message ? 1 : 0);

    if (currentScore > existingScore) {
      output.set(key, patchedItem);
    }
  }

  return Array.from(output.values());
}`,
      'app/customer-notifications.tsx -> add dedupeAndFixCustomerNotifications helper',
    );
  }

  content = replaceOrThrow(
    content,
    /setNotifications\(nextNotifications\);/,
    "setNotifications(dedupeAndFixCustomerNotifications(nextNotifications, customerName));",
    'app/customer-notifications.tsx -> setNotifications',
  );

  fs.writeFileSync(filePath, content, 'utf8');
  return { filePath, backupPath };
}

function main() {
  const projectRoot = process.cwd();
  const results = [];

  results.push(patchNotificationService(projectRoot));
  results.push(patchCustomerNotifications(projectRoot));

  console.log('Done successfully.');
  for (const result of results) {
    console.log(`Patched: ${result.filePath}`);
    console.log(`Backup : ${result.backupPath}`);
  }
  console.log('Next steps:');
  console.log('1) npm run typecheck');
  console.log('2) npx expo start -c');
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
}
