#!/usr/bin/env bash

# تحسين شامل لـ Render مع ذاكرة محدودة 512MB
echo "🚀 Render-Optimized Multi-Stream Server v6.0 (512MB)"

# تنظيف شامل
echo "🧹 Memory-efficient cleanup..."
pkill -f nginx 2>/dev/null || true
pkill -f ffmpeg 2>/dev/null || true
sleep 2

# دالة قراءة ملف التكوين
load_streams_config() {
    local config_file="$WORK_DIR/streams.conf"

    if [ ! -f "$config_file" ]; then
        echo "❌ ملف التكوين غير موجود: $config_file"
        exit 1
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
        echo "❌ لم يتم العثور على قنوات صالحة"
        exit 1
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

    # تنظيف ملفات الـ segments القديمة لتوفير مساحة (> دقيقة واحدة)
    find "$STREAM_DIR" -name "*.ts" -mmin +1 -delete 2>/dev/null || true
    
    echo "✅ تم التنظيف وتوفير الذاكرة"
}

# تحميل إعدادات القنوات
load_streams_config
cleanup_unused_directories

echo "🚀 Memory-Optimized Multi-Stream Server"
echo "📁 Stream dir: $STREAM_DIR"
echo "🌐 Port: $PORT"
echo "📺 Streams: ${#SOURCE_URLS[@]}"
echo "💾 Memory Mode: 512MB Optimized"

# دالة إنشاء nginx.conf محسن للذاكرة
generate_nginx_config() {
    echo "🔧 إنشاء nginx.conf محسن للذاكرة..."

    cat > "$NGINX_CONF" << EOF
# تحسين شامل للذاكرة المحدودة 512MB
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

    # تحسين الذاكرة - تقليل حجم المخازن المؤقتة
    client_body_buffer_size 8K;
    client_header_buffer_size 1k;
    client_max_body_size 1m;
    large_client_header_buffers 2 4k;

    # تحسين الأداء
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 100;

    # ضغط محسن
    gzip on;
    gzip_vary on;
    gzip_min_length 500;
    gzip_comp_level 3;
    gzip_types application/vnd.apple.mpegurl video/mp2t;

    # تقليل التسجيل لتوفير I/O
    access_log off;

    server {
        listen $PORT;
        server_name _;
        
        # تحسين المخازن المؤقتة
        client_body_timeout 10;
        client_header_timeout 10;
        send_timeout 10;
EOF

    # إضافة locations محسنة لكل قناة
    for i in "${!STREAM_NAMES[@]}"; do
        local stream_name="${STREAM_NAMES[$i]}"
        cat >> "$NGINX_CONF" << STREAMEOF

        # Stream: $stream_name (كشف تلقائي للجودة)
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

            location /$stream_name/source/ {
                alias $WORK_DIR/stream/$stream_name/source/;
            }

            location /$stream_name/alt/ {
                alias $WORK_DIR/stream/$stream_name/alt/;
            }
        }
STREAMEOF
    done

    cat >> "$NGINX_CONF" << EOF

        # P2P WebSocket Signaling Proxy
        location /ws {
            proxy_pass http://127.0.0.1:9000;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_read_timeout 86400;
        }

        # P2P Player & Static Files
        location / {
            root $WORK_DIR/public;
            try_files \$uri \$uri/ /player.html;
            add_header Cache-Control "public, max-age=300";
        }

        location /api/status {
            return 200 '{"status":"running","memory":"512MB-optimized","p2p":"enabled"}';
            add_header Content-Type application/json;
        }

        location /health {
            return 200 'OK - P2P Enabled';
            add_header Content-Type text/plain;
        }
    }
}
EOF

    echo "✅ تم إنشاء nginx.conf محسن للذاكرة"
}

generate_nginx_config

# إنشاء المجلدات بحد أدنى
mkdir -p "$LOGS_DIR" 2>/dev/null || true

for i in "${!SOURCE_URLS[@]}"; do
    STREAM_NAME="${STREAM_NAMES[$i]}"
    HLS_DIR="$STREAM_DIR/${STREAM_NAME}"

    echo "📁 إعداد: $STREAM_NAME"
    mkdir -p "$HLS_DIR" 2>/dev/null || true
    # تنظيف segments قديمة (> دقيقتين)
    find "$HLS_DIR" -name "*.ts" -mmin +2 -delete 2>/dev/null || true
done

echo "🌐 بدء nginx محسن للذاكرة..."
nginx -c "$NGINX_CONF" &
NGINX_PID=$!
sleep 1

# بدء P2P Signaling Server
if command -v node >/dev/null 2>&1; then
    echo "🔗 بدء P2P Signaling Server على المنفذ 9000..."
    export SIGNALING_PORT=9000
    node signaling-server.js > "$LOGS_DIR/signaling.log" 2>&1 &
    SIGNALING_PID=$!
    echo "✅ Signaling Server PID: $SIGNALING_PID"
else
    echo "⚠️ Node.js غير متوفر - P2P معطل"
    SIGNALING_PID=""
fi

# دالة كشف جودة المصدر باستخدام ffprobe
detect_source_resolution() {
    local source_url=$1
    
    echo "🔍 كشف جودة الفيديو المصدر..."
    
    # محاولة أولى مع headers كاملة
    local height=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height \
        -of default=noprint_wrappers=1:nokey=1 \
        -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        -headers "Referer: https://google.com"$'\r\n'"Accept: */*"$'\r\n'"Connection: keep-alive"$'\r\n' \
        -timeout 15000000 \
        -rw_timeout 15000000 \
        "$source_url" 2>&1 | grep -E '^[0-9]+$' | head -1)
    
    if [ -z "$height" ]; then
        echo "⚠️ فشل كشف الجودة للرابط: $source_url"
        echo "⚠️ استخدام 1080p افتراضياً"
        echo "1080"
        return
    fi
    
    if [ "$height" -ge 1080 ]; then
        echo "✅ المصدر: 1080p (${height}p)"
        echo "1080"
    elif [ "$height" -ge 720 ]; then
        echo "✅ المصدر: 720p (${height}p)"
        echo "720"
    else
        echo "⚠️ جودة غير معروفة ($height)، استخدام 720p افتراضياً"
        echo "720"
    fi
}

# دالة FFmpeg محسنة للذاكرة (نسخ جودة المصدر + جودة إضافية)
start_ffmpeg() {
    local stream_index=$1
    local source_url="${SOURCE_URLS[$stream_index]}"
    local stream_name="${STREAM_NAMES[$stream_index]}"
    local hls_dir="$STREAM_DIR/${stream_name}"

    echo "📺 بدء $stream_name (كشف تلقائي للجودة)..."
    
    # كشف جودة المصدر
    local source_res=$(detect_source_resolution "$source_url")

    mkdir -p "$hls_dir/source" "$hls_dir/alt" 2>/dev/null || true

    # تحديد الجودات بناءً على المصدر
    if [ "$source_res" = "1080" ]; then
        # المصدر 1080p: ننسخ الأصلي مباشرة + نضيف 720p
        echo "📊 إعداد: نسخ مباشر 1080p + إضافة 720p"
        
        ffmpeg -hide_banner -loglevel warning \
            -fflags +genpts+discardcorrupt+igndts \
            -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
            -headers "Referer: https://google.com"$'\r\n'"Accept: */*"$'\r\n'"Connection: keep-alive"$'\r\n' \
            -reconnect 1 -reconnect_at_eof 1 \
            -reconnect_streamed 1 -reconnect_delay_max 5 \
            -timeout 25000000 \
            -rw_timeout 25000000 \
            -analyzeduration 3000000 \
            -probesize 3000000 \
            -thread_queue_size 512 \
            -i "$source_url" \
            \
            -map 0:v -map 0:a \
            -c:v copy -c:a copy \
            -f hls -hls_time 6 -hls_list_size 8 \
            -hls_flags delete_segments+independent_segments \
            -hls_segment_type mpegts \
            -hls_segment_filename "$hls_dir/source/${stream_name}_source_%05d.ts" \
            -hls_delete_threshold 3 \
            "$hls_dir/source/index.m3u8" \
            \
            -map 0:v -map 0:a \
            -vf "scale=1280:720:flags=fast_bilinear" \
            -c:v libx264 -preset ultrafast -tune zerolatency \
            -profile:v main -level 3.0 \
            -b:v 1500k -maxrate 1650k -bufsize 1000k \
            -g 60 -keyint_min 30 -sc_threshold 0 \
            -c:a aac -b:a 64k -ac 2 -ar 44100 \
            -threads 1 \
            -f hls -hls_time 6 -hls_list_size 8 \
            -hls_flags delete_segments+independent_segments \
            -hls_segment_type mpegts \
            -hls_segment_filename "$hls_dir/alt/${stream_name}_720p_%05d.ts" \
            -hls_delete_threshold 3 \
            "$hls_dir/alt/index.m3u8" \
            > /dev/null 2>&1 &
        
        local ffmpeg_pid=$!
        FFMPEG_PIDS[$stream_index]=$ffmpeg_pid
        
        # Master Playlist
        cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
source/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1564000,RESOLUTION=1280x720,CODECS="avc1.4d401e,mp4a.40.2"
alt/index.m3u8
MASTER_EOF
        
    else
        # المصدر 720p: ننسخ الأصلي مباشرة + نضيف 1080p
        echo "📊 إعداد: نسخ مباشر 720p + إضافة 1080p"
        
        ffmpeg -hide_banner -loglevel warning \
            -fflags +genpts+discardcorrupt+igndts \
            -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
            -headers "Referer: https://google.com"$'\r\n'"Accept: */*"$'\r\n'"Connection: keep-alive"$'\r\n' \
            -reconnect 1 -reconnect_at_eof 1 \
            -reconnect_streamed 1 -reconnect_delay_max 5 \
            -timeout 25000000 \
            -rw_timeout 25000000 \
            -analyzeduration 3000000 \
            -probesize 3000000 \
            -thread_queue_size 512 \
            -i "$source_url" \
            \
            -map 0:v -map 0:a \
            -c:v copy -c:a copy \
            -f hls -hls_time 6 -hls_list_size 8 \
            -hls_flags delete_segments+independent_segments \
            -hls_segment_type mpegts \
            -hls_segment_filename "$hls_dir/source/${stream_name}_source_%05d.ts" \
            -hls_delete_threshold 3 \
            "$hls_dir/source/index.m3u8" \
            \
            -map 0:v -map 0:a \
            -vf "scale=1920:1080:flags=fast_bilinear" \
            -c:v libx264 -preset ultrafast -tune zerolatency \
            -profile:v main -level 3.1 \
            -b:v 3000k -maxrate 3300k -bufsize 2000k \
            -g 60 -keyint_min 30 -sc_threshold 0 \
            -c:a aac -b:a 96k -ac 2 -ar 44100 \
            -threads 1 \
            -f hls -hls_time 6 -hls_list_size 8 \
            -hls_flags delete_segments+independent_segments \
            -hls_segment_type mpegts \
            -hls_segment_filename "$hls_dir/alt/${stream_name}_1080p_%05d.ts" \
            -hls_delete_threshold 3 \
            "$hls_dir/alt/index.m3u8" \
            > /dev/null 2>&1 &
        
        local ffmpeg_pid=$!
        FFMPEG_PIDS[$stream_index]=$ffmpeg_pid
        
        # Master Playlist
        cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
source/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3096000,RESOLUTION=1920x1080,CODECS="avc1.4d401f,mp4a.40.2"
alt/index.m3u8
MASTER_EOF
    fi

    echo "✅ $stream_name جاهز (نسخ مباشر من المصدر)"
}

# بدء جميع عمليات FFmpeg
for i in "${!SOURCE_URLS[@]}"; do
    start_ffmpeg $i
    sleep 1
done

echo "✅ خادم محسن للذاكرة جاهز!"
echo "🌐 الرابط المحلي: http://0.0.0.0:$PORT"

# عرض روابط حسب البيئة
if [ "$RENDER" = "true" ]; then
    APP_NAME=${APP_NAME:-stream-server}
    echo "🔗 Render URL: https://$APP_NAME.onrender.com"
    echo "🔍 Health Check: https://$APP_NAME.onrender.com/health"
    echo ""
    echo "📡 روابط البث (كشف تلقائي للجودة):"
    for i in "${!STREAM_NAMES[@]}"; do
        echo "📺 ${STREAM_NAMES[$i]}:"
        echo "   🎯 Adaptive: https://$APP_NAME.onrender.com/${STREAM_NAMES[$i]}/master.m3u8"
        echo "   📥 Source: https://$APP_NAME.onrender.com/${STREAM_NAMES[$i]}/source/index.m3u8"
        echo "   🔄 Alt: https://$APP_NAME.onrender.com/${STREAM_NAMES[$i]}/alt/index.m3u8"
        echo ""
    done
elif [ "$REPLIT" = "true" ]; then
    echo "🔗 Replit Preview: https://$REPL_SLUG--$REPL_OWNER.replit.app"
    echo "🔍 Health Check: https://$REPL_SLUG--$REPL_OWNER.replit.app/health"
    echo ""
    echo "📡 روابط البث (كشف تلقائي للجودة):"
    for i in "${!STREAM_NAMES[@]}"; do
        echo "📺 ${STREAM_NAMES[$i]}:"
        echo "   🎯 Adaptive: https://$REPL_SLUG--$REPL_OWNER.replit.app/${STREAM_NAMES[$i]}/master.m3u8"
        echo "   📥 Source: https://$REPL_SLUG--$REPL_OWNER.replit.app/${STREAM_NAMES[$i]}/source/index.m3u8"
        echo "   🔄 Alt: https://$REPL_SLUG--$REPL_OWNER.replit.app/${STREAM_NAMES[$i]}/alt/index.m3u8"
        echo ""
    done
fi

echo "📊 العمليات النشطة: ${#FFMPEG_PIDS[@]} | Nginx PID: $NGINX_PID"
echo "💾 وضع الذاكرة: محسن لـ 512MB"

# مراقبة مبسطة ومحسنة للذاكرة
monitor_ffmpeg() {
    local stream_index=$1
    local stream_name="${STREAM_NAMES[$stream_index]}"
    local source_url="${SOURCE_URLS[$stream_index]}"
    local hls_dir="$STREAM_DIR/${stream_name}"

    while true; do
        sleep 20
        if ! kill -0 ${FFMPEG_PIDS[$stream_index]} 2>/dev/null; then
            echo "🔄 إعادة تشغيل $stream_name..."
            
            # كشف جودة المصدر
            local source_res=$(detect_source_resolution "$source_url")

            mkdir -p "$hls_dir/source" "$hls_dir/alt" 2>/dev/null || true

            # تحديد الجودات بناءً على المصدر
            if [ "$source_res" = "1080" ]; then
                # المصدر 1080p: ننسخ الأصلي مباشرة + نضيف 720p
                ffmpeg -hide_banner -loglevel warning \
                    -fflags +genpts+discardcorrupt+igndts \
                    -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
                    -headers "Referer: https://google.com"$'\r\n'"Accept: */*"$'\r\n'"Connection: keep-alive"$'\r\n' \
                    -reconnect 1 -reconnect_at_eof 1 \
                    -reconnect_streamed 1 -reconnect_delay_max 5 \
                    -timeout 25000000 \
                    -rw_timeout 25000000 \
                    -analyzeduration 3000000 \
                    -probesize 3000000 \
                    -thread_queue_size 512 \
                    -i "$source_url" \
                    \
                    -map 0:v -map 0:a \
                    -c:v copy -c:a copy \
                    -f hls -hls_time 6 -hls_list_size 8 \
                    -hls_flags delete_segments+independent_segments \
                    -hls_segment_type mpegts \
                    -hls_segment_filename "$hls_dir/source/${stream_name}_source_%05d.ts" \
                    -hls_delete_threshold 3 \
                    "$hls_dir/source/index.m3u8" \
                    \
                    -map 0:v -map 0:a \
                    -vf "scale=1280:720:flags=fast_bilinear" \
                    -c:v libx264 -preset ultrafast -tune zerolatency \
                    -profile:v main -level 3.0 \
                    -b:v 1500k -maxrate 1650k -bufsize 1000k \
                    -g 60 -keyint_min 30 -sc_threshold 0 \
                    -c:a aac -b:a 64k -ac 2 -ar 44100 \
                    -threads 1 \
                    -f hls -hls_time 6 -hls_list_size 8 \
                    -hls_flags delete_segments+independent_segments \
                    -hls_segment_type mpegts \
                    -hls_segment_filename "$hls_dir/alt/${stream_name}_720p_%05d.ts" \
                    -hls_delete_threshold 3 \
                    "$hls_dir/alt/index.m3u8" \
                    > /dev/null 2>&1 &
                
                FFMPEG_PIDS[$stream_index]=$!
                
                cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
source/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1564000,RESOLUTION=1280x720,CODECS="avc1.4d401e,mp4a.40.2"
alt/index.m3u8
MASTER_EOF
                
            else
                # المصدر 720p: ننسخ الأصلي مباشرة + نضيف 1080p
                ffmpeg -hide_banner -loglevel warning \
                    -fflags +genpts+discardcorrupt+igndts \
                    -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
                    -headers "Referer: https://google.com"$'\r\n'"Accept: */*"$'\r\n'"Connection: keep-alive"$'\r\n' \
                    -reconnect 1 -reconnect_at_eof 1 \
                    -reconnect_streamed 1 -reconnect_delay_max 5 \
                    -timeout 25000000 \
                    -rw_timeout 25000000 \
                    -analyzeduration 3000000 \
                    -probesize 3000000 \
                    -thread_queue_size 512 \
                    -i "$source_url" \
                    \
                    -map 0:v -map 0:a \
                    -c:v copy -c:a copy \
                    -f hls -hls_time 6 -hls_list_size 8 \
                    -hls_flags delete_segments+independent_segments \
                    -hls_segment_type mpegts \
                    -hls_segment_filename "$hls_dir/source/${stream_name}_source_%05d.ts" \
                    -hls_delete_threshold 3 \
                    "$hls_dir/source/index.m3u8" \
                    \
                    -map 0:v -map 0:a \
                    -vf "scale=1920:1080:flags=fast_bilinear" \
                    -c:v libx264 -preset ultrafast -tune zerolatency \
                    -profile:v main -level 3.1 \
                    -b:v 3000k -maxrate 3300k -bufsize 2000k \
                    -g 60 -keyint_min 30 -sc_threshold 0 \
                    -c:a aac -b:a 96k -ac 2 -ar 44100 \
                    -threads 1 \
                    -f hls -hls_time 6 -hls_list_size 8 \
                    -hls_flags delete_segments+independent_segments \
                    -hls_segment_type mpegts \
                    -hls_segment_filename "$hls_dir/alt/${stream_name}_1080p_%05d.ts" \
                    -hls_delete_threshold 3 \
                    "$hls_dir/alt/index.m3u8" \
                    > /dev/null 2>&1 &
                
                FFMPEG_PIDS[$stream_index]=$!
                
                cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
source/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3096000,RESOLUTION=1920x1080,CODECS="avc1.4d401f,mp4a.40.2"
alt/index.m3u8
MASTER_EOF
            fi

            echo "✅ $stream_name تم إعادة التشغيل"
        fi
    done
}

# بدء المراقبة
for i in "${!SOURCE_URLS[@]}"; do
    monitor_ffmpeg $i &
    MONITOR_PIDS[$i]=$!
done

# دالة إيقاف
cleanup() {
    echo "🛑 إيقاف الخدمات..."
    for pid in "${FFMPEG_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    for pid in "${MONITOR_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done
    kill $NGINX_PID 2>/dev/null || true
    if [ -n "$SIGNALING_PID" ]; then
        kill $SIGNALING_PID 2>/dev/null || true
    fi
    echo "✅ تم الإيقاف"
    exit 0
}

trap cleanup SIGTERM SIGINT

# حلقة رئيسية مع تنظيف دوري للذاكرة
while true; do
    sleep 90
    
    # تنظيف دوري للذاكرة (حذف segments > دقيقة ونصف)
    find "$STREAM_DIR" -name "*.ts" -mmin +2 -delete 2>/dev/null || true
    
    running_count=0
    for pid in "${FFMPEG_PIDS[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            ((running_count++))
        fi
    done

    echo "📊 الحالة: $running_count/${#FFMPEG_PIDS[@]} بث نشط | ذاكرة محسنة"
done
