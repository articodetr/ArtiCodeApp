const fs = require('fs');
const path = require('path');

function assertFile(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`File not found: ${filePath}`);
  }
}

function backupFile(filePath) {
  const backupPath = `${filePath}.backup-fix-duplicate-wrong-customer-notifications-${Date.now()}`;
  fs.copyFileSync(filePath, backupPath);
  return backupPath;
}

function replaceOrThrow(source, pattern, replacement, label) {
  if (!pattern.test(source)) {
    throw new Error(`Could not find target block for: ${label}`);
  }
  return source.replace(pattern, replacement);
}

function patchCustomerNotifications(projectRoot) {
  const filePath = path.join(projectRoot, 'app', 'customer-notifications.tsx');
  assertFile(filePath);
  const backupPath = backupFile(filePath);
  let content = fs.readFileSync(filePath, 'utf8');

  if (!content.includes('function dedupeAndFixCustomerNotifications(')) {
    content = replaceOrThrow(
      content,
      /function canTakeNotificationAction\([\s\S]*?\n\}\n\nfunction filterNotificationsLocally\(/,
      [
        `function canTakeNotificationAction(`,
        `  item: MovementNotification,`,
        `  currentUser?: CurrentUserLike,`,
        `) {`,
        `  const anyItem = item as any;`,
        `  const rawStatus = getNotificationRawStatus(item);`,
        ``,
        `  const isRecipient =`,
        `    sameId(anyItem.user_id, currentUser?.userId) ||`,
        `    sameId(anyItem.recipient_user_id, currentUser?.userId);`,
        ``,
        `  return (`,
        `    anyItem.notification_type === 'approval_needed' &&`,
        `    Boolean(anyItem.movement_id) &&`,
        `    anyItem.action_required !== false &&`,
        `    isRecipient &&`,
        `    !isNotificationCreatedByCurrentUser(item, currentUser) &&`,
        `    rawStatus !== 'approved' &&`,
        `    rawStatus !== 'rejected' &&`,
        `    rawStatus !== 'done'`,
        `  );`,
        `}`,
        ``,
        `function dedupeAndFixCustomerNotifications(`,
        `  notifications: MovementNotification[],`,
        `  currentUser?: CurrentUserLike,`,
        `  forcedCustomerName?: string,`,
        `) {`,
        `  const currentUserNames = [`,
        `    normalizeText(currentUser?.userName),`,
        `    normalizeText(currentUser?.fullName),`,
        `  ].filter(Boolean);`,
        ``,
        `  const forcedNameNormalized = normalizeText(forcedCustomerName);`,
        ``,
        `  const buildKey = (item: MovementNotification) => {`,
        `    const anyItem = item as any;`,
        `    const rawStatus = getNotificationRawStatus(item);`,
        ``,
        `    if (anyItem.movement_id && (rawStatus === 'pending' || anyItem.notification_type === 'approval_needed')) {`,
        `      return \`pending:\${String(anyItem.movement_id)}\`;`,
        `    }`,
        ``,
        `    return \`id:\${String(anyItem.id)}\`;`,
        `  };`,
        ``,
        `  const scoreItem = (item: MovementNotification) => {`,
        `    const anyItem = item as any;`,
        `    const createdByCurrentUser = isNotificationCreatedByCurrentUser(item, currentUser);`,
        `    const itemCustomerName = normalizeText(anyItem.customer_name || anyItem.movement?.customer?.name);`,
        `    const itemActorName = normalizeText(anyItem.actor_name || anyItem.movement?.created_by_user_name);`,
        `    let score = 0;`,
        ``,
        `    if (createdByCurrentUser) {`,
        `      if (forcedNameNormalized && itemCustomerName === forcedNameNormalized) score += 100;`,
        `      if (anyItem.action_required === false) score += 40;`,
        `      if (itemCustomerName && !currentUserNames.includes(itemCustomerName)) score += 25;`,
        `    } else {`,
        `      if (anyItem.action_required !== false) score += 40;`,
        `      if (itemActorName && !currentUserNames.includes(itemActorName)) score += 25;`,
        `    }`,
        ``,
        `    const createdAtScore = new Date(anyItem.created_at || 0).getTime();`,
        `    if (Number.isFinite(createdAtScore)) score += createdAtScore / 1e15;`,
        ``,
        `    return score;`,
        `  };`,
        ``,
        `  const bestByKey = new Map<string, MovementNotification>();`,
        ``,
        `  for (const item of notifications) {`,
        `    const key = buildKey(item);`,
        `    const currentBest = bestByKey.get(key);`,
        ``,
        `    if (!currentBest || scoreItem(item) > scoreItem(currentBest)) {`,
        `      bestByKey.set(key, item);`,
        `    }`,
        `  }`,
        ``,
        `  return Array.from(bestByKey.values())`,
        `    .map((item) => {`,
        `      const anyItem = item as any;`,
        `      const createdByCurrentUser = isNotificationCreatedByCurrentUser(item, currentUser);`,
        ``,
        `      if (forcedCustomerName && createdByCurrentUser && isNotificationPending(item)) {`,
        `        return {`,
        `          ...item,`,
        `          customer_name: forcedCustomerName,`,
        `          message: anyItem.message || item.message,`,
        `        };`,
        `      }`,
        ``,
        `      return item;`,
        `    })`,
        `    .sort(`,
        `      (a, b) => new Date((b as any).created_at || 0).getTime() - new Date((a as any).created_at || 0).getTime(),`,
        `    );`,
        `}`,
        ``,
        `function filterNotificationsLocally(`,
      ].join('\n'),
      'app/customer-notifications.tsx -> add dedupeAndFixCustomerNotifications helper',
    );
  }

  content = replaceOrThrow(
    content,
    /const nextNotifications = await getCustomerNotifications\(currentUser\.userId, customerId\);\s*\n\s*setNotifications\(nextNotifications\);/,
    [
      `const nextNotifications = await getCustomerNotifications(currentUser.userId, customerId);`,
      `      const fixedNotifications = dedupeAndFixCustomerNotifications(`,
      `        nextNotifications,`,
      `        currentUser,`,
      `        customerName,`,
      `      );`,
      `      setNotifications(fixedNotifications);`,
    ].join('\n'),
    'app/customer-notifications.tsx -> loadNotifications dedupe call',
  );

  content = replaceOrThrow(
    content,
    /\}, \[currentUser\?\.userId, customerId\]\);/,
    `}, [currentUser?.userId, currentUser?.userName, currentUser?.fullName, customerId, customerName]);`,
    'app/customer-notifications.tsx -> loadNotifications dependencies',
  );

  fs.writeFileSync(filePath, content, 'utf8');
  return { filePath, backupPath };
}

function main() {
  const projectRoot = process.cwd();
  const result = patchCustomerNotifications(projectRoot);
  console.log('Done successfully.');
  console.log(`Patched: ${result.filePath}`);
  console.log(`Backup : ${result.backupPath}`);
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
