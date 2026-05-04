const fs = require('fs');
const path = require('path');

function readFileSafe(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`File not found: ${filePath}`);
  }
  return fs.readFileSync(filePath, 'utf8');
}

function writeFileSafe(filePath, content) {
  fs.writeFileSync(filePath, content, 'utf8');
}

function replaceOnce(source, searchValue, replaceValue, label) {
  if (typeof searchValue === 'string') {
    if (!source.includes(searchValue)) {
      throw new Error(`Could not find target block for: ${label}`);
    }
    return source.replace(searchValue, replaceValue);
  }

  if (!searchValue.test(source)) {
    throw new Error(`Could not find target block for: ${label}`);
  }
  return source.replace(searchValue, replaceValue);
}

function patchGeneralNotifications(repoRoot) {
  const filePath = path.join(repoRoot, 'app', '(tabs)', 'notifications.tsx');
  let content = readFileSafe(filePath);
  let changed = false;

  const helperName = 'dedupeAndFixGeneralNotifications';
  if (!content.includes(`function ${helperName}(`)) {
    const helperBlock = `
function isNotificationNameForCurrentUser(
  value: unknown,
  currentUser?: CurrentUserLike,
) {
  const candidate = normalizeText(value);
  if (!candidate) return false;

  const currentNames = [currentUser?.userName, currentUser?.fullName]
    .map((item) => normalizeText(item))
    .filter(Boolean);

  return currentNames.includes(candidate);
}

function extractCustomerNameFromNotificationText(value?: unknown) {
  const text = String(value || '').trim();
  if (!text) return '';

  const patterns = [
    /أنت\s+قيدت\s+(?:على|لـ|ل)\s+(.+?)(?:\s+مبلغ|$)/u,
    /قيدت\s+(?:على|لـ|ل)\s+(.+?)(?:\s+مبلغ|$)/u,
    /تمت\s+موافقة\s+(.+?)\s+على\s+الحركة/u,
    /رفض\s+(.+?)\s+هذه\s+الحركة/u,
  ];

  for (const pattern of patterns) {
    const match = text.match(pattern);
    const extracted = String(match?.[1] || '').trim();
    if (extracted) {
      return extracted;
    }
  }

  return '';
}

function pickNotificationDisplayCustomerName(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
) {
  const anyItem = item as any;
  const movement = anyItem.movement || {};
  const extra = anyItem.extra_data || {};

  const candidates = [
    extractCustomerNameFromNotificationText(anyItem.title),
    extractCustomerNameFromNotificationText(anyItem.message),
    anyItem.customer_name,
    movement.customer?.name,
    extra.customer_name,
    extra.counterparty_name,
    extra.linked_customer_name,
  ];

  for (const candidate of candidates) {
    const cleaned = String(candidate || '').trim();
    if (!cleaned) continue;
    if (isNotificationNameForCurrentUser(cleaned, currentUser)) continue;
    return cleaned;
  }

  return '';
}

function patchNotificationForDisplay(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
): MovementNotification {
  const forcedCustomerName = pickNotificationDisplayCustomerName(item, currentUser);
  const anyItem = item as any;
  const movement = anyItem.movement || null;

  if (!forcedCustomerName) {
    return item;
  }

  return {
    ...item,
    customer_name: forcedCustomerName,
    movement: movement
      ? {
          ...movement,
          customer: {
            ...(movement.customer || {}),
            name: forcedCustomerName,
          },
        }
      : movement,
  };
}

function getGeneralNotificationVisualDedupKey(item: MovementNotification) {
  const rawStatus = getNotificationRawStatus(item);
  return item.movement_id
    ? [item.movement_id, rawStatus || item.notification_type || 'info'].join('::')
    : item.id;
}

function getGeneralNotificationVisualScore(
  item: MovementNotification,
  currentUser?: CurrentUserLike,
) {
  let score = 0;

  const displayCustomerName = pickNotificationDisplayCustomerName(item, currentUser);
  if (displayCustomerName) score += 20;
  if (item.message) score += 2;
  if (item.title) score += 2;
  if ((item as any).action_required === false) score += 1;
  if (!isNotificationNameForCurrentUser(item.customer_name, currentUser)) score += 8;
  if (!isNotificationNameForCurrentUser(item.movement?.customer?.name, currentUser)) score += 8;

  return score;
}

function dedupeAndFixGeneralNotifications(
  notifications: MovementNotification[],
  currentUser?: CurrentUserLike,
) {
  const output = new Map<string, MovementNotification>();

  for (const rawItem of notifications) {
    const patchedItem = patchNotificationForDisplay(rawItem, currentUser);
    const key = getGeneralNotificationVisualDedupKey(patchedItem);
    const existing = output.get(key);

    if (!existing) {
      output.set(key, patchedItem);
      continue;
    }

    const currentScore = getGeneralNotificationVisualScore(patchedItem, currentUser);
    const existingScore = getGeneralNotificationVisualScore(existing, currentUser);

    if (currentScore > existingScore) {
      output.set(key, patchedItem);
    }
  }

  return Array.from(output.values());
}
`;

    content = replaceOnce(
      content,
      /function searchNotificationsLocally\([\s\S]*?return notifications\.filter\(\(item\) => getNotificationSearchText\(item\)\.includes\(query\)\);\s*}\s*/,
      (match) => `${match}${helperBlock}\n`,
      'app/(tabs)/notifications.tsx -> insert general notification dedupe helper',
    );
    changed = true;
  }

  if (content.includes('setNotifications(nextNotifications);')) {
    content = replaceOnce(
      content,
      'setNotifications(nextNotifications);',
      'setNotifications(dedupeAndFixGeneralNotifications(nextNotifications, currentUser));',
      'app/(tabs)/notifications.tsx -> apply dedupe helper on load',
    );
    changed = true;
  }

  if (content.includes('}, [currentUser?.userId]);')) {
    content = replaceOnce(
      content,
      '}, [currentUser?.userId]);',
      '}, [currentUser?.fullName, currentUser?.userId, currentUser?.userName]);',
      'app/(tabs)/notifications.tsx -> expand useCallback deps for current user names',
    );
    changed = true;
  }

  if (changed) {
    writeFileSafe(filePath, content);
  }

  return { filePath, changed };
}

function patchCustomerNotifications(repoRoot) {
  const filePath = path.join(repoRoot, 'app', 'customer-notifications.tsx');
  if (!fs.existsSync(filePath)) {
    return { filePath, changed: false, skipped: true };
  }

  let content = readFileSafe(filePath);
  let changed = false;

  if (!content.includes('function dedupeAndFixCustomerNotifications(')) {
    const helperBlock = `
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
}
`;

    content = replaceOnce(
      content,
      /function searchNotificationsLocally\([\s\S]*?return notifications\.filter\(\(item\) => getNotificationSearchText\(item\)\.includes\(query\)\);\s*}\s*/,
      (match) => `${match}${helperBlock}\n`,
      'app/customer-notifications.tsx -> insert customer notification dedupe helper',
    );
    changed = true;
  }

  if (content.includes('setNotifications(nextNotifications);')) {
    content = replaceOnce(
      content,
      'setNotifications(nextNotifications);',
      'setNotifications(dedupeAndFixCustomerNotifications(nextNotifications, customerName));',
      'app/customer-notifications.tsx -> apply customer dedupe helper on load',
    );
    changed = true;
  }

  if (changed) {
    writeFileSafe(filePath, content);
  }

  return { filePath, changed };
}

function main() {
  const repoRoot = process.cwd();
  const results = [];

  results.push(patchGeneralNotifications(repoRoot));
  results.push(patchCustomerNotifications(repoRoot));

  const changedFiles = results.filter((item) => item.changed).map((item) => path.relative(repoRoot, item.filePath));
  const skippedFiles = results.filter((item) => item.skipped).map((item) => path.relative(repoRoot, item.filePath));

  if (!changedFiles.length) {
    console.log('No changes were needed. The notification duplicate fix appears to be already applied.');
  } else {
    console.log('Patched files:');
    for (const file of changedFiles) {
      console.log(`- ${file}`);
    }
  }

  if (skippedFiles.length) {
    console.log('Skipped files:');
    for (const file of skippedFiles) {
      console.log(`- ${file}`);
    }
  }
}

main();
