#!/bin/bash
export EXPO_TOKEN="wuHP7MsCQt_at86feHoq1QteFNIit5qQ6hUigE4L"

# Use a named pipe to simulate interactive input
mkfifo /tmp/eas_input || true
(echo "y" > /tmp/eas_input) &

npx eas-cli build --platform android --profile preview < /tmp/eas_input

rm -f /tmp/eas_input
