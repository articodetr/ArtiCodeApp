const { spawn } = require('child_process');

const EXPO_TOKEN = 't67dFVu9db_mswhd3k0t7bpMStVmQkOn7hBDFMBo';

async function runCommand(command, args, answers = []) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: { ...process.env, EXPO_TOKEN },
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let output = '';
    let answerIndex = 0;

    child.stdout.on('data', (data) => {
      const text = data.toString();
      output += text;
      process.stdout.write(text);

      if (answerIndex < answers.length) {
        const question = answers[answerIndex];
        if (text.includes(question.match)) {
          setTimeout(() => {
            child.stdin.write(question.answer + '\n');
            answerIndex++;
          }, 500);
        }
      }
    });

    child.stderr.on('data', (data) => {
      const text = data.toString();
      output += text;
      process.stderr.write(text);
    });

    child.on('close', (code) => {
      if (code === 0) {
        resolve(output);
      } else {
        reject(new Error(`Command failed with code ${code}`));
      }
    });

    child.on('error', reject);
  });
}

async function main() {
  console.log('Creating EAS project...');

  try {
    await runCommand('npx', ['eas-cli', 'build:configure'], [
      { match: 'Would you like to automatically create an EAS project', answer: 'y' },
      { match: 'Select a platform', answer: '\n' }
    ]);

    console.log('\n✅ EAS project created successfully!');
    console.log('\nNow you can run: npx eas-cli update --branch production');
  } catch (error) {
    console.error('❌ Error:', error.message);
    process.exit(1);
  }
}

main();
