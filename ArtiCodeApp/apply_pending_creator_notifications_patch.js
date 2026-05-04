const fs = require('fs');
const path = require('path');

function assertFile(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`File not found: ${filePath}`);
  }
}

function backupFile(filePath) {
  const backupPath = `${filePath}.backup-pending-creator-notifications-${Date.now()}`;
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

  content = replaceOrThrow(
    content,
    /function isNotificationPending\(item: MovementNotification\) \{[\s\S]*?return \([\s\S]*?Boolean\(anyItem\.movement\?\.pending_approval\)[\s\S]*?\);\s*\}/,
    [
      'function isNotificationPending(item: MovementNotification) {',
      '  const anyItem = item as any;',
      '  const rawStatus = getNotificationRawStatus(item);',
      '',
      "  if (rawStatus === 'approved' || rawStatus === 'rejected' || rawStatus === 'done') {",
      '    return false;',
      '  }',
      '',
      '  return (',
      "    rawStatus === 'pending' ||",
      "    anyItem.notification_type === 'approval_needed' ||",
      "    anyItem.notification_type === 'movement_pending' ||",
      '    Boolean(anyItem.action_required) ||',
      '    Boolean(anyItem.movement?.pending_approval)',
      '  );',
      '}',
    ].join('\n'),
    'app/customer-notifications.tsx -> isNotificationPending',
  );

  fs.writeFileSync(filePath, content, 'utf8');
  return { filePath, backupPath };
}

function patchNotificationService(projectRoot) {
  const filePath = path.join(projectRoot, 'services', 'notificationService.ts');
  assertFile(filePath);
  const backupPath = backupFile(filePath);
  let content = fs.readFileSync(filePath, 'utf8');

  content = replaceOrThrow(
    content,
    /export function isNotificationPending\(item: MovementNotification\) \{[\s\S]*?return \([\s\S]*?Boolean\(item\.movement\?\.pending_approval\)[\s\S]*?\);\s*\}/,
    [
      'export function isNotificationPending(item: MovementNotification) {',
      '  const rawStatus = getNotificationRawStatus(item);',
      '',
      "  if (rawStatus === 'approved' || rawStatus === 'rejected' || rawStatus === 'done') {",
      '    return false;',
      '  }',
      '',
      '  return (',
      "    rawStatus === 'pending' ||",
      "    item.notification_type === 'approval_needed' ||",
      "    item.notification_type === 'movement_pending' ||",
      '    Boolean(item.movement?.pending_approval)',
      '  );',
      '}',
    ].join('\n'),
    'services/notificationService.ts -> isNotificationPending',
  );

  content = replaceOrThrow(
    content,
    /\}\s*else if \(pending\) \{[\s\S]*?visualState = 'pending';\s*\}/,
    [
      '} else if (pending) {',
      "  if (item.notification_type === 'movement_pending') {",
      '    subtitle = customerName',
      '      ? `تم إرسال هذه الحركة إلى ${customerName} وهي بانتظار الموافقة قبل دخولها في الإجماليات.`',
      "      : 'تم إرسال هذه الحركة وهي بانتظار موافقة الطرف الآخر قبل دخولها في الإجماليات.';",
      '  } else {',
      "    subtitle = createdByCurrentUser ? `بانتظار موافقة ${customerName}.` : 'بانتظار الموافقة.';",
      '  }',
      '',
      "  statusText = 'معلقة';",
      '',
      "  statusColor = '#B45309';",
      '',
      "  statusBg = '#FEF3C7';",
      '',
      "  rowBorderColor = '#FBBF24';",
      '',
      "  rowBg = '#FFFBEB';",
      '',
      "  visualState = 'pending';",
      '}',
    ].join('\n'),
    'services/notificationService.ts -> pending display branch',
  );

  fs.writeFileSync(filePath, content, 'utf8');
  return { filePath, backupPath };
}

function main() {
  const projectRoot = process.cwd();
  const results = [];

  results.push(patchCustomerNotifications(projectRoot));
  results.push(patchNotificationService(projectRoot));

  console.log('Done successfully.');
  for (const result of results) {
    console.log(`Patched: ${result.filePath}`);
    console.log(`Backup : ${result.backupPath}`);
  }
  console.log('Next steps:');
  console.log('1) Copy the SQL migration from supabase/migrations into your project');
  console.log('2) Run your Supabase migration flow');
  console.log('3) npm run typecheck');
  console.log('4) Restart Expo / app');
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
}
