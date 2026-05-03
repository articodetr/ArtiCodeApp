#!/bin/bash

export EXPO_TOKEN="DidnkNik64Xc4qVEmPRJHK-ceFS3Pn3GrQPcfPrK"

# Use expect to handle interactive prompts
expect << 'EOF'
set timeout 180
spawn npx eas-cli build --platform android --profile preview

expect {
    "Generate a new Android Keystore?" {
        send "Y\r"
        exp_continue
    }
    "Would you like" {
        send "Y\r"
        exp_continue
    }
    "let Expo handle" {
        send "Y\r"
        exp_continue
    }
    "Build started" {
        puts "Build started successfully!"
    }
    timeout {
        puts "Timeout waiting for response"
        exit 1
    }
    eof
}
EOF
