#!/usr/bin/env bash

echo "🚀 Starting Multi-Stream Server on Render..."

# تعيين متغيرات البيئة لـ Render
export RENDER=true
export PLATFORM=render
export HOST=0.0.0.0
export PORT=${PORT:-10000}

# إنشاء المجلدات المطلوبة
mkdir -p stream/logs
mkdir -p /var/log/nginx /var/lib/nginx /run
chmod +x perfect_stream.sh
chmod 755 stream

echo "📦 All dependencies ready on Render"
echo "🌐 Starting on port $PORT"

# تشغيل السكريبت الرئيسي
exec bash ./perfect_stream.sh
