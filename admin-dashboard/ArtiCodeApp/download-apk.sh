#!/bin/bash

echo "تحميل أحدث APK من EAS..."
echo ""

# تسجيل الدخول
export EXPO_TOKEN="ZO6ucB1r6vpVhPc5JrxRqu86_Sbx21pAC1LmujwI"

# تحميل آخر بناء Android
npx eas-cli build:download --platform android --latest --output ./altarf-app.apk

echo ""
echo "✅ تم التحميل بنجاح!"
echo "📱 الملف: ./altarf-app.apk"
