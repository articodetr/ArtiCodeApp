const { spawn } = require('child_process');

const child = spawn('npx', ['eas-cli', 'build', '--platform', 'android', '--profile', 'preview'], {
  env: {
    ...process.env,
    EXPO_TOKEN: 'wuHP7MsCQt_at86feHoq1QteFNIit5qQ6hUigE4L'
  },
  stdio: ['pipe', 'inherit', 'inherit']
});

child.stdin.write('y\n');
child.stdin.end();

child.on('close', (code) => {
  console.log(`Build process exited with code ${code}`);
  process.exit(code);
});
