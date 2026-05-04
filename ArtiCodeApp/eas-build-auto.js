const { spawn } = require('child_process');
const readline = require('readline');

process.env.EXPO_TOKEN = 'wuHP7MsCQt_at86feHoq1QteFNIit5qQ6hUigE4L';

const child = spawn('npx', ['eas-cli', 'build', '--profile', 'preview', '--platform', 'android', '--clear-cache'], {
  stdio: ['pipe', 'pipe', 'pipe'],
  env: { ...process.env },
  cwd: __dirname
});

const rl = readline.createInterface({
  input: child.stdout,
  terminal: false
});

rl.on('line', (line) => {
  console.log(line);

  // Auto-respond to prompts
  if (line.includes('Would you like to automatically create an EAS project') ||
      line.includes('Would you like to create a project')) {
    child.stdin.write('y\n');
  }

  if (line.includes('Generate a new Android Keystore')) {
    child.stdin.write('y\n');
  }
});

child.stderr.on('data', (data) => {
  console.error(data.toString());
});

child.on('close', (code) => {
  console.log(`Process exited with code ${code}`);
  process.exit(code);
});

// Handle timeout
setTimeout(() => {
  console.log('Timeout - killing process');
  child.kill();
  process.exit(1);
}, 600000); // 10 minutes
