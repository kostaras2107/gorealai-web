@echo off
cd /d C:\shoppilot

echo ===== FLUTTER CLEAN =====
flutter clean

echo ===== PUB GET =====
flutter pub get

echo ===== BUILD WEB =====
flutter build web --base-href /app/ --release

echo ===== COPY TO LANDING =====
robocopy build\web landing\app /E >nul

echo ===== FIREBASE DEPLOY =====
firebase deploy --only hosting:gorealai

echo.
echo ===== DONE =====
pause