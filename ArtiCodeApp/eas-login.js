const { spawn } = require('child_process');
const readline = require('readline');

const username = 'arti_code';
const password = 'jlal99662870502';

console.log('Starting EAS CLI login...');

const eas = spawn('npx', ['eas-cli', 'login'], {
  stdio: ['pipe', 'pipe', 'pipe']
});

let output = '';

eas.stdout.on('data', (data) => {
  const text = data.toString();
  output += text;
  console.log(text);

  // Check for username prompt
  if (text.toLowerCase().includes('email or username') || text.toLowerCase().includes('username')) {
    console.log(`Sending username: ${username}`);
    eas.stdin.write(username + '\n');
  }

  // Check for password prompt
  if (text.toLowerCase().includes('password')) {
    console.log('Sending password...');
    eas.stdin.write(password + '\n');
  }

  // Check for success
  if (text.toLowerCase().includes('logged in') || text.toLowerCase().includes('success')) {
    console.log('Login successful!');
    eas.stdin.end();
  }
});

eas.stderr.on('data', (data) => {
  console.error(data.toString());
});

eas.on('close', (code) => {
  console.log(`Process exited with code ${code}`);
  if (code === 0) {
    console.log('Login completed successfully!');
  } else {
    console.log('Login failed!');
  }
  process.exit(code);
});

// Timeout after 60 seconds
setTimeout(() => {
  console.log('Timeout reached, killing process...');
  eas.kill();
  process.exit(1);
}, 60000);
