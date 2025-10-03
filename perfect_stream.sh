#!/usr/bin/env bash

# نسخ مباشر من المصدر بدون transcoding
echo "🚀 Direct Copy Streaming Server v7.0"

# تنظيف شامل
echo "🧹 تنظيف العمليات القديمة..."
pkill -f nginx 2>/dev/null || true
pkill -f ffmpeg 2>/dev/null || true
sleep 2

# دالة قراءة ملف التكوين
load_streams_config() {
    local config_file="$WORK_DIR/streams.conf"

    if [ ! -f "$config_file" ]; then
        echo "⚠️  ملف التكوين غير موجود، إنشاء ملف جديد..."
        echo "# قنوات البث - صيغة: اسم_القناة|رابط_البث_m3u8" > "$config_file"
        echo "# مثال: ch1|https://example.com/stream.m3u8" >> "$config_file"
        echo "✅ تم إنشاء $config_file - استخدم لوحة التحكم لإضافة القنوات"
    fi

    declare -ga SOURCE_URLS=()
    declare -ga STREAM_NAMES=()

    echo "📖 قراءة ملف التكوين: $config_file"

    while IFS='|' read -r stream_name source_url; do
        if [[ -z "$stream_name" || "$stream_name" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        stream_name=$(echo "$stream_name" | xargs)
        source_url=$(echo "$source_url" | xargs)

        if [[ -n "$stream_name" && -n "$source_url" ]]; then
            STREAM_NAMES+=("$stream_name")
            SOURCE_URLS+=("$source_url")
            echo "📺 تمت إضافة: $stream_name"
        fi
    done < "$config_file"

    if [ ${#STREAM_NAMES[@]} -eq 0 ]; then
        echo "⚠️  لا توجد قنوات في التكوين"
        echo "🎛️  افتح لوحة التحكم لإضافة القنوات"
        return 0
    fi

    echo "✅ تم تحميل ${#STREAM_NAMES[@]} قناة"
}

WORK_DIR="$(pwd)"
STREAM_DIR="$WORK_DIR/stream"
LOGS_DIR="$STREAM_DIR/logs"
NGINX_CONF="$WORK_DIR/nginx.conf"
PORT=${PORT:-10000}
HOST="0.0.0.0"

# كشف بيئة Replit
if [ "$REPL_SLUG" ]; then
    echo "🔧 Replit environment detected"
    export REPLIT=true
fi

declare -a FFMPEG_PIDS=()
declare -a MONITOR_PIDS=()

# دالة تنظيف المجلدات
cleanup_unused_directories() {
    echo "🧹 تنظيف ذكي للذاكرة..."

    if [ -d "$STREAM_DIR" ]; then
        for dir in "$STREAM_DIR"/ch*; do
            if [ -d "$dir" ]; then
                stream_name_from_folder=$(basename "$dir")
                found=false
                for active_stream in "${STREAM_NAMES[@]}"; do
                    if [ "$stream_name_from_folder" = "$active_stream" ]; then
                        found=true
                        break
                    fi
                done

                if [ "$found" = false ]; then
                    echo "🗑️ حذف مجلد غير مستخدم: $dir"
                    rm -rf "$dir" 2>/dev/null || true
                fi
            fi
        done
    fi

    # تنظيف ملفات الـ segments القديمة جداً (> 5 دقائق للأمان)
    find "$STREAM_DIR" -name "*.ts" -mmin +5 -delete 2>/dev/null || true
    
    echo "✅ تم التنظيف"
}

# تحميل إعدادات القنوات
load_streams_config
cleanup_unused_directories

echo "🚀 Direct Copy Streaming Server"
echo "📁 Stream dir: $STREAM_DIR"
echo "🌐 Port: $PORT"
echo "📺 Streams: ${#SOURCE_URLS[@]}"
echo "⚡ Mode: Copy Direct (No Transcoding)"

# دالة إنشاء nginx.conf
generate_nginx_config() {
    echo "🔧 إنشاء nginx.conf..."

    cat > "$NGINX_CONF" << EOF
worker_processes 1;
worker_rlimit_nofile 1024;
error_log $WORK_DIR/stream/logs/nginx_error.log error;
pid $WORK_DIR/stream/logs/nginx.pid;

events {
    worker_connections 512;
    use epoll;
    multi_accept off;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    client_body_buffer_size 8K;
    client_header_buffer_size 1k;
    client_max_body_size 1m;
    large_client_header_buffers 2 4k;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 100;

    gzip on;
    gzip_vary on;
    gzip_min_length 500;
    gzip_comp_level 3;
    gzip_types application/vnd.apple.mpegurl video/mp2t;

    access_log off;

    server {
        listen $PORT;
        server_name _;
        
        client_body_timeout 10;
        client_header_timeout 10;
        send_timeout 10;
EOF

    # إضافة locations لكل قناة
    for i in "${!STREAM_NAMES[@]}"; do
        local stream_name="${STREAM_NAMES[$i]}"
        cat >> "$NGINX_CONF" << STREAMEOF

        # Stream: $stream_name (نسخ مباشر)
        location /$stream_name/ {
            alias $WORK_DIR/stream/$stream_name/;
            
            add_header Access-Control-Allow-Origin "*";
            add_header Cache-Control "no-cache";
            expires off;

            location ~* \.m3u8$ {
                add_header Cache-Control "no-cache, must-revalidate";
                expires off;
            }

            location ~* \.ts$ {
                add_header Cache-Control "public, max-age=6";
                expires 6s;
            }
        }
STREAMEOF
    done

    cat >> "$NGINX_CONF" << EOF

        # Admin API Proxy
        location /api/ {
            proxy_pass http://127.0.0.1:8080/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        # Static Files & Player
        location / {
            root $WORK_DIR/public;
            try_files \$uri \$uri/ /player.html;
            add_header Cache-Control "public, max-age=300";
        }

        location /health {
            return 200 'OK - Direct Copy Mode';
            add_header Content-Type text/plain;
        }
    }
}
EOF

    echo "✅ تم إنشاء nginx.conf"
}

generate_nginx_config

# إنشاء المجلدات
mkdir -p "$LOGS_DIR" 2>/dev/null || true
mkdir -p "$WORK_DIR/public" 2>/dev/null || true
chmod -R 755 "$WORK_DIR/public" 2>/dev/null || true

# التأكد من وجود player.html
if [ ! -f "$WORK_DIR/public/player.html" ]; then
    echo "⚠️ player.html غير موجود في public/"
fi

for i in "${!SOURCE_URLS[@]}"; do
    STREAM_NAME="${STREAM_NAMES[$i]}"
    HLS_DIR="$STREAM_DIR/${STREAM_NAME}"

    echo "📁 إعداد: $STREAM_NAME"
    mkdir -p "$HLS_DIR" 2>/dev/null || true
done

echo "🌐 بدء nginx..."
nginx -c "$NGINX_CONF" &
NGINX_PID=$!
sleep 1

# بدء Admin API Server
if command -v node >/dev/null 2>&1; then
    echo "🎛️  بدء Admin API Server على المنفذ 8080..."
    export ADMIN_PORT=8080
    node admin-api.js > "$LOGS_DIR/admin-api.log" 2>&1 &
    ADMIN_API_PID=$!
    sleep 1
    if kill -0 $ADMIN_API_PID 2>/dev/null; then
        echo "✅ Admin API PID: $ADMIN_API_PID (يعمل)"
    else
        echo "❌ فشل تشغيل Admin API - تحقق من $LOGS_DIR/admin-api.log"
    fi
else
    echo "⚠️ Node.js غير متوفر - Admin API معطل"
    ADMIN_API_PID=""
fi

# دالة FFmpeg - نسخ مباشر مع إعدادات متوازنة ومستقرة
start_ffmpeg() {
    local stream_index=$1
    local source_url="${SOURCE_URLS[$stream_index]}"
    local stream_name="${STREAM_NAMES[$stream_index]}"
    local hls_dir="$STREAM_DIR/${stream_name}"

    echo "📺 بدء $stream_name (نسخ مباشر - إعدادات محسنة)..."

    mkdir -p "$hls_dir" 2>/dev/null || true
    
    # حذف المقاطع القديمة للبدء من الصفر
    rm -f "$hls_dir"/*.ts "$hls_dir"/*.m3u8 2>/dev/null || true

    ffmpeg -hide_banner -loglevel error \
        -fflags +genpts+discardcorrupt+igndts+nobuffer \
        -flags low_delay \
        -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        -headers "Referer: https://google.com"$'\r\n'"Accept: */*"$'\r\n'"Connection: keep-alive"$'\r\n' \
        -reconnect 1 \
        -reconnect_at_eof 1 \
        -reconnect_streamed 1 \
        -reconnect_on_network_error 1 \
        -reconnect_on_http_error 4xx,5xx \
        -reconnect_delay_max 10 \
        -timeout 60000000 \
        -rw_timeout 30000000 \
        -analyzeduration 5000000 \
        -probesize 5000000 \
        -max_delay 500000 \
        -thread_queue_size 1024 \
        -i "$source_url" \
        -map 0:v? -map 0:a? \
        -c copy \
        -copyts \
        -start_at_zero \
        -avoid_negative_ts make_zero \
        -f hls \
        -hls_time 4 \
        -hls_list_size 12 \
        -hls_flags delete_segments+omit_endlist \
        -hls_segment_type mpegts \
        -hls_segment_filename "$hls_dir/${stream_name}_%05d.ts" \
        -hls_delete_threshold 2 \
        -hls_start_number_source epoch \
        -master_pl_publish_rate 5 \
        "$hls_dir/index.m3u8" \
        >> "$LOGS_DIR/${stream_name}_ffmpeg.log" 2>&1 &

    local ffmpeg_pid=$!
    FFMPEG_PIDS[$stream_index]=$ffmpeg_pid

    echo "✅ $stream_name جاهز (نسخ مباشر - استقرار عالي)"
}

# بدء جميع عمليات FFmpeg (إن وجدت)
if [ ${#SOURCE_URLS[@]} -gt 0 ]; then
    for i in "${!SOURCE_URLS[@]}"; do
        start_ffmpeg $i
        sleep 1
    done
else
    echo "⚠️  لا توجد قنوات للبث - استخدم لوحة التحكم لإضافة القنوات"
fi

echo "✅ خادم نسخ مباشر جاهز!"
echo "🌐 الرابط المحلي: http://0.0.0.0:$PORT"

# عرض روابط حسب البيئة
if [ "$RENDER" = "true" ]; then
    APP_NAME=${APP_NAME:-stream-server}
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔗 Render URL: https://$APP_NAME.onrender.com"
    echo "🎛️  لوحة التحكم: https://$APP_NAME.onrender.com/admin.html"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "🔍 Health Check: https://$APP_NAME.onrender.com/health"
    echo ""
    echo "📡 روابط البث (نسخ مباشر):"
    for i in "${!STREAM_NAMES[@]}"; do
        echo "📺 ${STREAM_NAMES[$i]}: https://$APP_NAME.onrender.com/${STREAM_NAMES[$i]}/index.m3u8"
    done
elif [ "$REPLIT" = "true" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔗 Replit Preview: https://$REPL_SLUG--$REPL_OWNER.replit.app"
    echo "🎛️  لوحة التحكم: https://$REPL_SLUG--$REPL_OWNER.replit.app/admin.html"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "🔍 Health Check: https://$REPL_SLUG--$REPL_OWNER.replit.app/health"
    echo ""
    echo "📡 روابط البث (نسخ مباشر):"
    for i in "${!STREAM_NAMES[@]}"; do
        echo "📺 ${STREAM_NAMES[$i]}: https://$REPL_SLUG--$REPL_OWNER.replit.app/${STREAM_NAMES[$i]}/index.m3u8"
    done
fi

echo "📊 العمليات النشطة: ${#FFMPEG_PIDS[@]} | Nginx PID: $NGINX_PID"
echo "⚡ وضع النسخ المباشر: استهلاك CPU وذاكرة أقل بكثير"

# مراقبة محسنة مع إعادة تشغيل ذكية
monitor_ffmpeg() {
    local stream_index=$1
    local stream_name="${STREAM_NAMES[$stream_index]}"
    local source_url="${SOURCE_URLS[$stream_index]}"
    local hls_dir="$STREAM_DIR/${stream_name}"
    local restart_count=0

    while true; do
        sleep 15
        if ! kill -0 ${FFMPEG_PIDS[$stream_index]} 2>/dev/null; then
            ((restart_count++))
            echo "🔄 إعادة تشغيل $stream_name (المحاولة: $restart_count)..."
            
            sleep 3

            mkdir -p "$hls_dir" 2>/dev/null || true
            
            # حذف المقاطع القديمة للبدء من الصفر
            rm -f "$hls_dir"/*.ts "$hls_dir"/*.m3u8 2>/dev/null || true

            ffmpeg -hide_banner -loglevel error \
                -fflags +genpts+discardcorrupt+igndts+nobuffer \
                -flags low_delay \
                -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
                -headers "Referer: https://google.com"$'\r\n'"Accept: */*"$'\r\n'"Connection: keep-alive"$'\r\n' \
                -reconnect 1 \
                -reconnect_at_eof 1 \
                -reconnect_streamed 1 \
                -reconnect_on_network_error 1 \
                -reconnect_on_http_error 4xx,5xx \
                -reconnect_delay_max 10 \
                -timeout 60000000 \
                -rw_timeout 30000000 \
                -analyzeduration 5000000 \
                -probesize 5000000 \
                -max_delay 500000 \
                -thread_queue_size 1024 \
                -i "$source_url" \
                -map 0:v? -map 0:a? \
                -c copy \
                -copyts \
                -start_at_zero \
                -avoid_negative_ts make_zero \
                -f hls \
                -hls_time 4 \
                -hls_list_size 12 \
                -hls_flags delete_segments+omit_endlist \
                -hls_segment_type mpegts \
                -hls_segment_filename "$hls_dir/${stream_name}_%05d.ts" \
                -hls_delete_threshold 2 \
                -hls_start_number_source epoch \
                -master_pl_publish_rate 5 \
                "$hls_dir/index.m3u8" \
                >> "$LOGS_DIR/${stream_name}_ffmpeg.log" 2>&1 &

            FFMPEG_PIDS[$stream_index]=$!

            echo "✅ $stream_name تم إعادة التشغيل بنجاح"
        fi
    done
}

# بدء المراقبة (إن وجدت قنوات)
if [ ${#SOURCE_URLS[@]} -gt 0 ]; then
    for i in "${!SOURCE_URLS[@]}"; do
        monitor_ffmpeg $i &
        MONITOR_PIDS[$i]=$!
    done
fi

# بدء مراقبة ملف التحكم
watch_control_file &
WATCH_PID=$!

# دالة إيقاف
cleanup() {
    echo "🛑 إيقاف الخدمات..."
    for pid in "${FFMPEG_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    for pid in "${MONITOR_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    [ -n "$WATCH_PID" ] && kill $WATCH_PID 2>/dev/null || true
    [ -n "$ADMIN_API_PID" ] && kill $ADMIN_API_PID 2>/dev/null || true
    kill $NGINX_PID 2>/dev/null || true
    echo "✅ تم الإيقاف"
}

# دالة إعادة تحميل القنوات
reload_streams() {
    echo "🔄 إعادة تحميل القنوات..."
    
    # إيقاف جميع عمليات FFmpeg الحالية
    for pid in "${FFMPEG_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    for pid in "${MONITOR_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    
    sleep 2
    
    # إعادة تحميل التكوين
    SOURCE_URLS=()
    STREAM_NAMES=()
    load_streams_config
    cleanup_unused_directories
    
    # إعادة إنشاء nginx config
    generate_nginx_config
    nginx -s reload 2>/dev/null || true
    
    # إعادة بدء FFmpeg لكل قناة
    FFMPEG_PIDS=()
    MONITOR_PIDS=()
    for i in "${!SOURCE_URLS[@]}"; do
        start_ffmpeg $i
        sleep 1
    done
    
    # إعادة بدء المراقبة
    for i in "${!SOURCE_URLS[@]}"; do
        monitor_ffmpeg $i &
        MONITOR_PIDS[$i]=$!
    done
    
    echo "✅ تم إعادة تحميل القنوات بنجاح"
}

# دالة مراقبة ملف التحكم
watch_control_file() {
    local control_file="$STREAM_DIR/control.json"
    local last_check=0
    
    while true; do
        sleep 5
        
        if [ -f "$control_file" ]; then
            local file_time=$(stat -c %Y "$control_file" 2>/dev/null || stat -f %m "$control_file" 2>/dev/null)
            
            if [ "$file_time" -gt "$last_check" ]; then
                last_check=$file_time
                echo "📡 تم الكشف عن طلب إعادة تحميل من لوحة التحكم"
                reload_streams
                rm -f "$control_file" 2>/dev/null || true
            fi
        fi
    done
}

trap cleanup EXIT INT TERM

# حلقة المراقبة الرئيسية مع تنظيف دوري
while true; do
    sleep 60
    running_count=0
    for i in "${!FFMPEG_PIDS[@]}"; do
        if kill -0 ${FFMPEG_PIDS[$i]} 2>/dev/null; then
            ((running_count++))
        fi
    done
    
    echo "📊 الحالة: $running_count/${#FFMPEG_PIDS[@]} بث نشط | استقرار عالي"
done
