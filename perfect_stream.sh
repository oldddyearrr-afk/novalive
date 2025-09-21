
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

    # تنظيف ملفات الـ segments القديمة لتوفير مساحة
    find "$STREAM_DIR" -name "*.ts" -mtime +1 -delete 2>/dev/null || true
    
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

        # Stream: $stream_name (جودتين فقط لتوفير الذاكرة)
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

            location /$stream_name/ultra/ {
                alias $WORK_DIR/stream/$stream_name/ultra/;
            }

            location /$stream_name/high/ {
                alias $WORK_DIR/stream/$stream_name/high/;
            }
        }
STREAMEOF
    done

    cat >> "$NGINX_CONF" << 'EOF'

        location /api/status {
            return 200 '{"status":"running","memory":"512MB-optimized"}';
            add_header Content-Type application/json;
        }

        location / {
            return 200 'Render Optimized Stream Server Running';
            add_header Content-Type text/plain;
        }

        location /health {
            return 200 'OK - Memory Optimized';
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
    # تنظيف أقل تدخلاً
    find "$HLS_DIR" -name "*.ts" -mmin +5 -delete 2>/dev/null || true
done

echo "🌐 بدء nginx محسن للذاكرة..."
nginx -c "$NGINX_CONF" &
NGINX_PID=$!
sleep 1

# دالة FFmpeg محسنة للذاكرة (جودتين فقط)
start_ffmpeg() {
    local stream_index=$1
    local source_url="${SOURCE_URLS[$stream_index]}"
    local stream_name="${STREAM_NAMES[$stream_index]}"
    local hls_dir="$STREAM_DIR/${stream_name}"

    echo "📺 بدء $stream_name (جودتين محسنتين للذاكرة)..."

    mkdir -p "$hls_dir/ultra" "$hls_dir/high" 2>/dev/null || true

    # إعدادات محسنة للذاكرة المحدودة
    ffmpeg -hide_banner -loglevel error \
        -fflags +genpts+discardcorrupt \
        -user_agent "Mozilla/5.0" \
        -reconnect 1 -reconnect_at_eof 1 \
        -reconnect_delay_max 2 \
        -timeout 15000000 \
        -analyzeduration 500000 \
        -probesize 500000 \
        -thread_queue_size 256 \
        -i "$source_url" \
        \
        -filter_complex "[0:v]split=2[v1][v2]; \
                        [v1]scale=1920:1080:flags=fast_bilinear[v1080p]; \
                        [v2]scale=1280:720:flags=fast_bilinear[v720p]" \
        \
        -map "[v1080p]" -map 0:a \
        -c:v libx264 -preset ultrafast -tune zerolatency \
        -profile:v main -level 3.1 \
        -b:v 3000k -maxrate 3300k -bufsize 2000k \
        -g 50 -keyint_min 25 -sc_threshold 0 \
        -c:a aac -b:a 96k -ac 2 -ar 44100 \
        -threads 2 \
        -f hls -hls_time 3 -hls_list_size 4 \
        -hls_flags delete_segments+independent_segments \
        -hls_segment_filename "$hls_dir/ultra/${stream_name}_1080p_%03d.ts" \
        -hls_delete_threshold 1 \
        "$hls_dir/ultra/index.m3u8" \
        \
        -map "[v720p]" -map 0:a \
        -c:v libx264 -preset ultrafast -tune zerolatency \
        -profile:v main -level 3.0 \
        -b:v 1500k -maxrate 1650k -bufsize 1000k \
        -g 50 -keyint_min 25 -sc_threshold 0 \
        -c:a aac -b:a 64k -ac 2 -ar 44100 \
        -threads 1 \
        -f hls -hls_time 3 -hls_list_size 4 \
        -hls_flags delete_segments+independent_segments \
        -hls_segment_filename "$hls_dir/high/${stream_name}_720p_%03d.ts" \
        -hls_delete_threshold 1 \
        "$hls_dir/high/index.m3u8" \
        > /dev/null 2>&1 &

    local ffmpeg_pid=$!
    FFMPEG_PIDS[$stream_index]=$ffmpeg_pid

    # Master Playlist مبسط
    cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=3096000,RESOLUTION=1920x1080,CODECS="avc1.4d401f,mp4a.40.2"
ultra/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1564000,RESOLUTION=1280x720,CODECS="avc1.4d401e,mp4a.40.2"
high/index.m3u8
MASTER_EOF

    echo "✅ $stream_name جاهز (محسن للذاكرة)"
}

# بدء جميع عمليات FFmpeg
for i in "${!SOURCE_URLS[@]}"; do
    start_ffmpeg $i
    sleep 1
done

echo "✅ خادم محسن للذاكرة جاهز!"
echo "🌐 الرابط المحلي: http://0.0.0.0:$PORT"

# عرض روابط Render
if [ "$RENDER" = "true" ]; then
    APP_NAME=${APP_NAME:-stream-server}
    echo "🔗 Render URL: https://$APP_NAME.onrender.com"
    echo "🔍 Health Check: https://$APP_NAME.onrender.com/health"
    echo ""
    echo "📡 روابط البث المحسنة:"
    for i in "${!STREAM_NAMES[@]}"; do
        echo "📺 ${STREAM_NAMES[$i]}:"
        echo "   🎯 Adaptive: https://$APP_NAME.onrender.com/${STREAM_NAMES[$i]}/master.m3u8"
        echo "   🔥 1080p: https://$APP_NAME.onrender.com/${STREAM_NAMES[$i]}/ultra/index.m3u8"
        echo "   🔸 720p: https://$APP_NAME.onrender.com/${STREAM_NAMES[$i]}/high/index.m3u8"
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

            mkdir -p "$hls_dir/ultra" "$hls_dir/high" 2>/dev/null || true

            ffmpeg -hide_banner -loglevel error \
                -fflags +genpts+discardcorrupt \
                -user_agent "Mozilla/5.0" \
                -reconnect 1 -reconnect_at_eof 1 \
                -reconnect_delay_max 2 \
                -timeout 15000000 \
                -analyzeduration 500000 \
                -probesize 500000 \
                -thread_queue_size 256 \
                -i "$source_url" \
                \
                -filter_complex "[0:v]split=2[v1][v2]; \
                                [v1]scale=1920:1080:flags=fast_bilinear[v1080p]; \
                                [v2]scale=1280:720:flags=fast_bilinear[v720p]" \
                \
                -map "[v1080p]" -map 0:a \
                -c:v libx264 -preset ultrafast -tune zerolatency \
                -profile:v main -level 3.1 \
                -b:v 3000k -maxrate 3300k -bufsize 2000k \
                -g 50 -keyint_min 25 -sc_threshold 0 \
                -c:a aac -b:a 96k -ac 2 -ar 44100 \
                -threads 2 \
                -f hls -hls_time 3 -hls_list_size 4 \
                -hls_flags delete_segments+independent_segments \
                -hls_segment_filename "$hls_dir/ultra/${stream_name}_1080p_%03d.ts" \
                -hls_delete_threshold 1 \
                "$hls_dir/ultra/index.m3u8" \
                \
                -map "[v720p]" -map 0:a \
                -c:v libx264 -preset ultrafast -tune zerolatency \
                -profile:v main -level 3.0 \
                -b:v 1500k -maxrate 1650k -bufsize 1000k \
                -g 50 -keyint_min 25 -sc_threshold 0 \
                -c:a aac -b:a 64k -ac 2 -ar 44100 \
                -threads 1 \
                -f hls -hls_time 3 -hls_list_size 4 \
                -hls_flags delete_segments+independent_segments \
                -hls_segment_filename "$hls_dir/high/${stream_name}_720p_%03d.ts" \
                -hls_delete_threshold 1 \
                "$hls_dir/high/index.m3u8" \
                > /dev/null 2>&1 &

            FFMPEG_PIDS[$stream_index]=$!

            cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=3096000,RESOLUTION=1920x1080,CODECS="avc1.4d401f,mp4a.40.2"
ultra/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1564000,RESOLUTION=1280x720,CODECS="avc1.4d401e,mp4a.40.2"
high/index.m3u8
MASTER_EOF

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
    echo "✅ تم الإيقاف"
    exit 0
}

trap cleanup SIGTERM SIGINT

# حلقة رئيسية مع تنظيف دوري للذاكرة
while true; do
    sleep 90
    
    # تنظيف دوري للذاكرة
    find "$STREAM_DIR" -name "*.ts" -mmin +3 -delete 2>/dev/null || true
    
    running_count=0
    for pid in "${FFMPEG_PIDS[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            ((running_count++))
        fi
    done

    echo "📊 الحالة: $running_count/${#FFMPEG_PIDS[@]} بث نشط | ذاكرة محسنة"
done
