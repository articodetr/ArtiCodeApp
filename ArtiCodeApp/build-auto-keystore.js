const { spawn } = require('child_process');

console.log('Starting EAS build with automatic keystore generation...');

const eas = spawn('npx', ['eas-cli', 'build', '--platform', 'android', '--profile', 'preview'], {
  stdio: ['pipe', 'pipe', 'pipe'],
  env: {
    ...process.env,
    EXPO_TOKEN: 'DidnkNik64Xc4qVEmPRJHK-ceFS3Pn3GrQPcfPrK'
  }
});

let output = '';

eas.stdout.on('data', (data) => {
  const text = data.toString();
  output += text;
  console.log(text);

  if (text.includes('Generate new keystore') || text.includes('Would you like to generate a Keystore')) {
    console.log('Auto-responding: YES to generate keystore');
    eas.stdin.write('Y\n');
  }

  if (text.includes('Would you like Expo to handle') || text.includes('let Expo handle')) {
    console.log('Auto-responding: YES');
    eas.stdin.write('Y\n');
  }

  if (text.includes('Build started') || text.includes('Build link:')) {
    console.log('Build initiated successfully!');
  }
});

eas.stderr.on('data', (data) => {
  const text = data.toString();
  console.error(text);

  if (text.includes('Generate new keystore') || text.includes('Would you like to generate a Keystore')) {
    console.log('Auto-responding: YES to generate keystore');
    eas.stdin.write('Y\n');
  }
});

eas.on('close', (code) => {
  console.log(`Process exited with code ${code}`);
  process.exit(code);
});

setTimeout(() => {
  console.log('Timeout reached...');
  eas.kill();
  process.exit(1);
}, 180000);
