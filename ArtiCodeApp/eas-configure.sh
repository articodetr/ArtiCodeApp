#!/bin/bash
export EXPO_TOKEN="t67dFVu9db_mswhd3k0t7bpMStVmQkOn7hBDFMBo"

# استخدام expect لأتمتة التهيئة
expect << 'EOF'
spawn npx eas-cli build:configure
expect {
    "Would you like to automatically create an EAS project" {
        send "y\r"
        exp_continue
    }
    "Select a platform" {
        send "All\r"
        exp_continue
    }
    eof
}
EOF
