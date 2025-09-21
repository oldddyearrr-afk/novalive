#!/bin/bash

# تثبيت المتطلبات على Replit
echo "📦 Installing dependencies on Replit..."
if ! command -v ffmpeg &> /dev/null; then
    echo "Installing FFmpeg..."
    # استخدام nix لتثبيت المتطلبات على Replit
    nix-env -iA nixpkgs.ffmpeg nixpkgs.nginx nixpkgs.curl 2>/dev/null || true
    # أو استخدام sudo إذا كان متاحاً
    sudo apt-get update && sudo apt-get install -y ffmpeg nginx curl 2>/dev/null || true
fi

# تنظيف شامل
echo "🧹 Multi-Stream cleanup..."
pkill -f nginx 2>/dev/null || true
pkill -f ffmpeg 2>/dev/null || true
sleep 3

# دالة قراءة ملف التكوين المبسط
load_streams_config() {
    local config_file="$WORK_DIR/streams.conf"

    if [ ! -f "$config_file" ]; then
        echo "❌ ملف التكوين غير موجود: $config_file"
        exit 1
    fi

    declare -ga SOURCE_URLS=()
    declare -ga STREAM_NAMES=()

    echo "📖 قراءة ملف التكوين المبسط: $config_file"

    while IFS='|' read -r stream_name source_url; do
        # تجاهل الأسطر الفارغة والتعليقات
        if [[ -z "$stream_name" || "$stream_name" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # إزالة المسافات الزائدة
        stream_name=$(echo "$stream_name" | xargs)
        source_url=$(echo "$source_url" | xargs)

        if [[ -n "$stream_name" && -n "$source_url" ]]; then
            STREAM_NAMES+=("$stream_name")
            SOURCE_URLS+=("$source_url")
            echo "📺 تمت إضافة القناة: $stream_name"
        fi
    done < "$config_file"

    if [ ${#STREAM_NAMES[@]} -eq 0 ]; then
        echo "❌ لم يتم العثور على قنوات صالحة في ملف التكوين"
        exit 1
    fi

    echo "✅ تم تحميل ${#STREAM_NAMES[@]} قناة من ملف التكوين المبسط"
}

WORK_DIR="$(pwd)"
STREAM_DIR="$WORK_DIR/stream"
LOGS_DIR="$STREAM_DIR/logs"
NGINX_CONF="$WORK_DIR/nginx.conf"
PORT=${PORT:-5000}
HOST="0.0.0.0"
export REPL_SLUG="${REPL_SLUG:-stream-server}"
export REPL_OWNER="${REPL_OWNER:-user}"

# تأكيد أن البورت صحيح لـ Replit
if [ -n "$REPLIT_DEV_DOMAIN" ]; then
    echo "🌐 Running on Replit, using port $PORT"
    echo "🔗 Preview URL: https://$REPLIT_DEV_DOMAIN"
fi

declare -a FFMPEG_PIDS=()
declare -a MONITOR_PIDS=()

# دالة تنظيف المجلدات غير المستخدمة
cleanup_unused_directories() {
    echo "🧹 تنظيف المجلدات غير المستخدمة..."

    # الحصول على قائمة المجلدات الموجودة
    if [ -d "$STREAM_DIR" ]; then
        for dir in "$STREAM_DIR"/ch*; do
            if [ -d "$dir" ]; then
                # استخراج اسم القناة من المجلد
                stream_name_from_folder=$(basename "$dir")

                # التحقق إذا كانت القناة موجودة في القائمة الحالية
                found=false
                for active_stream in "${STREAM_NAMES[@]}"; do
                    if [ "$stream_name_from_folder" = "$active_stream" ]; then
                        found=true
                        break
                    fi
                done

                # إذا لم توجد القناة في القائمة الحالية، احذف المجلد
                if [ "$found" = false ]; then
                    echo "🗑️ حذف مجلد غير مستخدم: $dir"
                    rm -rf "$dir" 2>/dev/null || true
                fi
            fi
        done
    fi

    echo "✅ تم تنظيف المجلدات غير المستخدمة"
}

# تحميل إعدادات القنوات من ملف التكوين
load_streams_config

# تنظيف المجلدات غير المستخدمة بعد تحميل القنوات الجديدة
cleanup_unused_directories

echo "🚀 Ultra-Stable Multi-Stream Server v5.0"
echo "📁 Stream dir: $STREAM_DIR"
echo "🌐 Port: $PORT"
echo "📺 Streams: ${#SOURCE_URLS[@]}"

# دالة إنشاء nginx configuration ديناميكياً
generate_nginx_config() {
    echo "🔧 إنشاء nginx.conf ديناميكياً للقنوات ${#STREAM_NAMES[@]}..."

    cat > "$NGINX_CONF" << EOF
worker_processes auto;
error_log $WORK_DIR/stream/logs/nginx_error.log warn;
pid $WORK_DIR/stream/logs/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
    accept_mutex off;
}

http {
    types {
        text/html                             html htm;
        text/css                              css;
        application/javascript                js;
        application/vnd.apple.mpegurl         m3u8;
        video/mp2t                            ts;
        application/json                      json;
        application/octet-stream              bin;
    }
    default_type application/octet-stream;

    access_log $WORK_DIR/stream/logs/nginx_access.log;
    client_body_temp_path $WORK_DIR/stream/logs/client_temp;
    proxy_temp_path $WORK_DIR/stream/logs/proxy_temp;
    fastcgi_temp_path $WORK_DIR/stream/logs/fastcgi_temp;
    uwsgi_temp_path $WORK_DIR/stream/logs/uwsgi_temp;
    scgi_temp_path $WORK_DIR/stream/logs/scgi_temp;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    reset_timedout_connection on;
    client_body_timeout 12;
    client_header_timeout 12;
    send_timeout 10;

    # تحسين Buffer sizes
    client_body_buffer_size 16K;
    client_header_buffer_size 1k;
    client_max_body_size 8m;
    large_client_header_buffers 4 16k;

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_comp_level 6;
    gzip_types text/plain application/vnd.apple.mpegurl video/mp2t application/json text/css application/javascript;

    server {
        listen $PORT;
        server_name _;
EOF

    # إضافة location blocks لكل قناة ديناميكياً
    for i in "${!STREAM_NAMES[@]}"; do
        local stream_name="${STREAM_NAMES[$i]}"
        cat >> "$NGINX_CONF" << STREAMEOF

        # Stream: $stream_name (Multi-Quality Support)
        location /$stream_name/ {
            alias $WORK_DIR/stream/$stream_name/;

            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Range" always;
            add_header Accept-Ranges "bytes";

            # Master playlist و Sub-playlists
            location ~* \.m3u8$ {
                add_header Cache-Control "no-cache, no-store, must-revalidate";
                add_header Pragma "no-cache";
                add_header Expires "0";
                add_header X-Accel-Buffering "no";
                expires off;
            }

            # Video segments for all qualities
            location ~* \.ts$ {
                add_header Cache-Control "public, max-age=8";
                add_header X-Accel-Buffering "no";
                expires 8s;
                sendfile on;
                tcp_nopush off;
                aio threads;
                directio 512;
            }

            # Sub-locations for different qualities
            location /$stream_name/ultra/ {
                alias $WORK_DIR/stream/$stream_name/ultra/;
            }

            location /$stream_name/high/ {
                alias $WORK_DIR/stream/$stream_name/high/;
            }

            location /$stream_name/medium/ {
                alias $WORK_DIR/stream/$stream_name/medium/;
            }

            location /$stream_name/low/ {
                alias $WORK_DIR/stream/$stream_name/low/;
            }
        }
STREAMEOF
    done

    # إضافة الأجزاء الثابتة المتبقية
    cat >> "$NGINX_CONF" << 'EOF'

        # API for stream status
        location /api/status {
            return 200 '{"status":"running","server":"dynamic-multi-stream-server"}';
            add_header Content-Type application/json;
        }

        # Simple main page
        location / {
            return 200 'the broadcast is on';
            add_header Content-Type text/plain;
        }

        # Health check endpoint
        location /health {
            return 200 'OK - Dynamic Multi-Stream Server Running';
            add_header Content-Type text/plain;
        }
    }
}
EOF

    echo "✅ تم إنشاء nginx.conf مع ${#STREAM_NAMES[@]} قناة"
}


# إنشاء nginx configuration ديناميكياً
generate_nginx_config

# إنشاء المجلدات المطلوبة لكل بث
mkdir -p "$LOGS_DIR" 2>/dev/null || true
mkdir -p "$LOGS_DIR/client_temp" "$LOGS_DIR/proxy_temp" "$LOGS_DIR/fastcgi_temp" "$LOGS_DIR/uwsgi_temp" "$LOGS_DIR/scgi_temp" 2>/dev/null || true

for i in "${!SOURCE_URLS[@]}"; do
    STREAM_NAME="${STREAM_NAMES[$i]}"
    HLS_DIR="$STREAM_DIR/${STREAM_NAME}"

    echo "📁 Setting up stream: $STREAM_NAME"
    mkdir -p "$HLS_DIR" 2>/dev/null || true
    find "$HLS_DIR" -name "*.ts" -delete 2>/dev/null || true
    find "$HLS_DIR" -name "*.m3u8" -delete 2>/dev/null || true
done

rm -f "$LOGS_DIR"/*.log "$LOGS_DIR"/*.pid 2>/dev/null || true

echo "🌐 Starting nginx (multi-stream config)..."
nginx -c "$NGINX_CONF" &
NGINX_PID=$!
sleep 2

# دالة لبدء FFmpeg مع دعم متعدد الجودات (ABR)
start_ffmpeg() {
    local stream_index=$1
    local source_url="${SOURCE_URLS[$stream_index]}"
    local stream_name="${STREAM_NAMES[$stream_index]}"
    local hls_dir="$STREAM_DIR/${stream_name}"

    echo "📺 Starting $stream_name with Multi-Quality ABR..."

    # إنشاء مجلدات فرعية للجودات المختلفة (1080p، 720p، 480p، 360p)
    mkdir -p "$hls_dir/ultra" "$hls_dir/high" "$hls_dir/medium" "$hls_dir/low" 2>/dev/null || true

    ffmpeg -hide_banner -loglevel error \
        -fflags +genpts+discardcorrupt+flush_packets+igndts \
        -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 \
        -reconnect_delay_max 3 \
        -timeout 20000000 \
        -analyzeduration 1000000 \
        -probesize 1000000 \
        -thread_queue_size 1024 \
        -i "$source_url" \
        \
        -filter_complex "[0:v]split=4[v1][v2][v3][v4]; \
                        [v1]scale=1920:1080:flags=fast_bilinear,fps=25[v1080p]; \
                        [v2]scale=1280:720:flags=fast_bilinear,fps=25[v720p]; \
                        [v3]scale=854:480:flags=fast_bilinear,fps=25[v480p]; \
                        [v4]scale=640:360:flags=fast_bilinear,fps=25[v360p]" \
        \
        -map "[v1080p]" -map 0:a \
        -c:v libx264 -preset veryfast -tune zerolatency \
        -profile:v high -level 4.0 \
        -b:v 4000k -maxrate 4400k -bufsize 8000k \
        -g 50 -keyint_min 25 -sc_threshold 0 \
        -c:a aac -b:a 128k -ac 2 -ar 48000 \
        -avoid_negative_ts make_zero \
        -f hls -hls_time 4 -hls_list_size 6 \
        -hls_flags delete_segments+independent_segments+split_by_time \
        -hls_segment_filename "$hls_dir/ultra/${stream_name}_1080p_%04d.ts" \
        -hls_delete_threshold 2 -hls_allow_cache 0 \
        "$hls_dir/ultra/index.m3u8" \
        \
        -map "[v720p]" -map 0:a \
        -c:v libx264 -preset veryfast -tune zerolatency \
        -profile:v high -level 3.1 \
        -b:v 2000k -maxrate 2200k -bufsize 4000k \
        -g 50 -keyint_min 25 -sc_threshold 0 \
        -c:a aac -b:a 96k -ac 2 -ar 44100 \
        -avoid_negative_ts make_zero \
        -f hls -hls_time 4 -hls_list_size 6 \
        -hls_flags delete_segments+independent_segments+split_by_time \
        -hls_segment_filename "$hls_dir/high/${stream_name}_720p_%04d.ts" \
        -hls_delete_threshold 2 -hls_allow_cache 0 \
        "$hls_dir/high/index.m3u8" \
        \
        -map "[v480p]" -map 0:a \
        -c:v libx264 -preset veryfast -tune zerolatency \
        -profile:v main -level 3.0 \
        -b:v 1000k -maxrate 1100k -bufsize 2000k \
        -g 50 -keyint_min 25 -sc_threshold 0 \
        -c:a aac -b:a 64k -ac 2 -ar 44100 \
        -avoid_negative_ts make_zero \
        -f hls -hls_time 4 -hls_list_size 6 \
        -hls_flags delete_segments+independent_segments+split_by_time \
        -hls_segment_filename "$hls_dir/medium/${stream_name}_480p_%04d.ts" \
        -hls_delete_threshold 2 -hls_allow_cache 0 \
        "$hls_dir/medium/index.m3u8" \
        \
        -map "[v360p]" -map 0:a \
        -c:v libx264 -preset veryfast -tune zerolatency \
        -profile:v baseline -level 3.0 \
        -b:v 500k -maxrate 550k -bufsize 1000k \
        -g 50 -keyint_min 25 -sc_threshold 0 \
        -c:a aac -b:a 64k -ac 2 -ar 44100 \
        -avoid_negative_ts make_zero \
        -f hls -hls_time 4 -hls_list_size 6 \
        -hls_flags delete_segments+independent_segments+split_by_time \
        -hls_segment_filename "$hls_dir/low/${stream_name}_360p_%04d.ts" \
        -hls_delete_threshold 2 -hls_allow_cache 0 \
        "$hls_dir/low/index.m3u8" \
        > "$LOGS_DIR/${stream_name}_ffmpeg.log" 2>&1 &

    local ffmpeg_pid=$!
    FFMPEG_PIDS[$stream_index]=$ffmpeg_pid

    # إنشاء Master Playlist للتبديل التلقائي بين الجودات مع إعدادات محسنة
    cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=4128000,AVERAGE-BANDWIDTH=4000000,RESOLUTION=1920x1080,FRAME-RATE=25.000,CODECS="avc1.640028,mp4a.40.2",NAME="1080p"
ultra/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2096000,AVERAGE-BANDWIDTH=2000000,RESOLUTION=1280x720,FRAME-RATE=25.000,CODECS="avc1.64001f,mp4a.40.2",NAME="720p"
high/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1064000,AVERAGE-BANDWIDTH=1000000,RESOLUTION=854x480,FRAME-RATE=25.000,CODECS="avc1.4d001e,mp4a.40.2",NAME="480p"
medium/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=548000,AVERAGE-BANDWIDTH=500000,RESOLUTION=640x360,FRAME-RATE=25.000,CODECS="avc1.42001e,mp4a.40.2",NAME="360p"
low/index.m3u8
MASTER_EOF

    echo "✅ $stream_name Multi-Quality ABR ready! (720p/480p/360p)"
}

# بدء جميع عمليات FFmpeg
for i in "${!SOURCE_URLS[@]}"; do
    start_ffmpeg $i
    sleep 1
done

echo "✅ Multi-Stream Server Running!"
echo "🌐 Local Interface: http://0.0.0.0:$PORT"

# عرض الرابط الصحيح لـ Replit
if [ -n "$REPLIT_DEV_DOMAIN" ]; then
    echo "🔗 Replit Preview: https://$REPLIT_DEV_DOMAIN"
    echo "🔍 Health Check: https://$REPLIT_DEV_DOMAIN/health"
    echo ""
    echo "📡 Multi-Quality Stream URLs:"
    for i in "${!STREAM_NAMES[@]}"; do
        echo "📺 ${STREAM_NAMES[$i]} - Adaptive (Master): https://$REPLIT_DEV_DOMAIN/${STREAM_NAMES[$i]}/master.m3u8"
        echo "   🔥 1080p UHD: https://$REPLIT_DEV_DOMAIN/${STREAM_NAMES[$i]}/ultra/index.m3u8"
        echo "   🔸 720p HD: https://$REPLIT_DEV_DOMAIN/${STREAM_NAMES[$i]}/high/index.m3u8"
        echo "   🔸 480p SD: https://$REPLIT_DEV_DOMAIN/${STREAM_NAMES[$i]}/medium/index.m3u8"  
        echo "   🔸 360p LD: https://$REPLIT_DEV_DOMAIN/${STREAM_NAMES[$i]}/low/index.m3u8"
        echo ""
    done
else
    echo "🔗 Preview URL: https://${REPL_SLUG}.${REPL_OWNER}.repl.co"
    echo "🔗 Alternative: https://${REPL_SLUG}-${REPL_OWNER}.replit.app"
    echo ""
    echo "📡 Multi-Quality Stream URLs:"
    for i in "${!STREAM_NAMES[@]}"; do
        echo "📺 ${STREAM_NAMES[$i]} - Adaptive (Master): https://${REPL_SLUG}.${REPL_OWNER}.repl.co/${STREAM_NAMES[$i]}/master.m3u8"
        echo "   🔥 1080p UHD: https://${REPL_SLUG}.${REPL_OWNER}.repl.co/${STREAM_NAMES[$i]}/ultra/index.m3u8"
        echo "   🔸 720p HD: https://${REPL_SLUG}.${REPL_OWNER}.repl.co/${STREAM_NAMES[$i]}/high/index.m3u8"
        echo "   🔸 480p SD: https://${REPL_SLUG}.${REPL_OWNER}.repl.co/${STREAM_NAMES[$i]}/medium/index.m3u8"
        echo "   🔸 360p LD: https://${REPL_SLUG}.${REPL_OWNER}.repl.co/${STREAM_NAMES[$i]}/low/index.m3u8"
        echo ""
    done
    echo "🔍 للتشخيص، افتح: https://${REPL_SLUG}.${REPL_OWNER}.repl.co/health"
fi

echo "📊 Total FFmpeg processes: ${#FFMPEG_PIDS[@]} | Nginx PID: $NGINX_PID"
echo ""

# دالة مراقبة FFmpeg مع دعم متعدد الجودات
monitor_ffmpeg() {
    local stream_index=$1
    local stream_name="${STREAM_NAMES[$stream_index]}"
    local source_url="${SOURCE_URLS[$stream_index]}"
    local hls_dir="$STREAM_DIR/${stream_name}"

    while true; do
        sleep 15
        if ! kill -0 ${FFMPEG_PIDS[$stream_index]} 2>/dev/null; then
            echo "🔄 $stream_name Multi-Quality FFmpeg crashed, restarting..."

            # إعادة إنشاء المجلدات الفرعية
            mkdir -p "$hls_dir/ultra" "$hls_dir/high" "$hls_dir/medium" "$hls_dir/low" 2>/dev/null || true

            ffmpeg -hide_banner -loglevel error \
                -fflags +genpts+discardcorrupt+flush_packets+igndts \
                -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 \
                -reconnect_delay_max 3 \
                -timeout 20000000 \
                -analyzeduration 1000000 \
                -probesize 1000000 \
                -thread_queue_size 1024 \
                -i "$source_url" \
                \
                -filter_complex "[0:v]split=4[v1][v2][v3][v4]; \
                                [v1]scale=1920:1080:flags=fast_bilinear,fps=25[v1080p]; \
                                [v2]scale=1280:720:flags=fast_bilinear,fps=25[v720p]; \
                                [v3]scale=854:480:flags=fast_bilinear,fps=25[v480p]; \
                                [v4]scale=640:360:flags=fast_bilinear,fps=25[v360p]" \
                \
                -map "[v1080p]" -map 0:a \
                -c:v libx264 -preset veryfast -tune zerolatency \
                -profile:v high -level 4.0 \
                -b:v 4000k -maxrate 4400k -bufsize 8000k \
                -g 50 -keyint_min 25 -sc_threshold 0 \
                -c:a aac -b:a 128k -ac 2 -ar 48000 \
                -avoid_negative_ts make_zero \
                -f hls -hls_time 4 -hls_list_size 6 \
                -hls_flags delete_segments+independent_segments+split_by_time \
                -hls_segment_filename "$hls_dir/ultra/${stream_name}_1080p_%04d.ts" \
                -hls_delete_threshold 2 -hls_allow_cache 0 \
                "$hls_dir/ultra/index.m3u8" \
                \
                -map "[v720p]" -map 0:a \
                -c:v libx264 -preset veryfast -tune zerolatency \
                -profile:v high -level 3.1 \
                -b:v 2000k -maxrate 2200k -bufsize 4000k \
                -g 50 -keyint_min 25 -sc_threshold 0 \
                -c:a aac -b:a 96k -ac 2 -ar 44100 \
                -avoid_negative_ts make_zero \
                -f hls -hls_time 4 -hls_list_size 6 \
                -hls_flags delete_segments+independent_segments+split_by_time \
                -hls_segment_filename "$hls_dir/high/${stream_name}_720p_%04d.ts" \
                -hls_delete_threshold 2 -hls_allow_cache 0 \
                "$hls_dir/high/index.m3u8" \
                \
                -map "[v480p]" -map 0:a \
                -c:v libx264 -preset veryfast -tune zerolatency \
                -profile:v main -level 3.0 \
                -b:v 1000k -maxrate 1100k -bufsize 2000k \
                -g 50 -keyint_min 25 -sc_threshold 0 \
                -c:a aac -b:a 64k -ac 2 -ar 44100 \
                -avoid_negative_ts make_zero \
                -f hls -hls_time 4 -hls_list_size 6 \
                -hls_flags delete_segments+independent_segments+split_by_time \
                -hls_segment_filename "$hls_dir/medium/${stream_name}_480p_%04d.ts" \
                -hls_delete_threshold 2 -hls_allow_cache 0 \
                "$hls_dir/medium/index.m3u8" \
                \
                -map "[v360p]" -map 0:a \
                -c:v libx264 -preset veryfast -tune zerolatency \
                -profile:v baseline -level 3.0 \
                -b:v 500k -maxrate 550k -bufsize 1000k \
                -g 50 -keyint_min 25 -sc_threshold 0 \
                -c:a aac -b:a 64k -ac 2 -ar 44100 \
                -avoid_negative_ts make_zero \
                -f hls -hls_time 4 -hls_list_size 6 \
                -hls_flags delete_segments+independent_segments+split_by_time \
                -hls_segment_filename "$hls_dir/low/${stream_name}_360p_%04d.ts" \
                -hls_delete_threshold 2 -hls_allow_cache 0 \
                "$hls_dir/low/index.m3u8" \
                > "$LOGS_DIR/${stream_name}_ffmpeg.log" 2>&1 &

            FFMPEG_PIDS[$stream_index]=$!

            # إعادة إنشاء Master Playlist المحسن
            cat > "$hls_dir/master.m3u8" << MASTER_EOF
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=4128000,AVERAGE-BANDWIDTH=4000000,RESOLUTION=1920x1080,FRAME-RATE=25.000,CODECS="avc1.640028,mp4a.40.2",NAME="1080p"
ultra/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2096000,AVERAGE-BANDWIDTH=2000000,RESOLUTION=1280x720,FRAME-RATE=25.000,CODECS="avc1.64001f,mp4a.40.2",NAME="720p"
high/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1064000,AVERAGE-BANDWIDTH=1000000,RESOLUTION=854x480,FRAME-RATE=25.000,CODECS="avc1.4d001e,mp4a.40.2",NAME="480p"
medium/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=548000,AVERAGE-BANDWIDTH=500000,RESOLUTION=640x360,FRAME-RATE=25.000,CODECS="avc1.42001e,mp4a.40.2",NAME="360p"
low/index.m3u8
MASTER_EOF

            echo "✅ $stream_name Multi-Quality restarted (PID: ${FFMPEG_PIDS[$stream_index]})"
        fi
    done
}



# بدء مراقبة مبسطة لكل بث
for i in "${!SOURCE_URLS[@]}"; do
    monitor_ffmpeg $i &
    MONITOR_PIDS[$i]=$!
    echo "📊 Started simple monitoring for ${STREAM_NAMES[$i]} (Monitor PID: ${MONITOR_PIDS[$i]})"
done

# دالة إيقاف محسنة
cleanup() {
    echo "🛑 Stopping all multi-stream services..."

    # إيقاف جميع عمليات FFmpeg
    for pid in "${FFMPEG_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done

    # إيقاف جميع عمليات المراقبة
    for pid in "${MONITOR_PIDS[@]}"; do
        kill $pid 2>/dev/null || true
    done

    # إيقاف Nginx
    kill $NGINX_PID 2>/dev/null || true

    echo "✅ All multi-stream services stopped."
    exit 0
}

trap cleanup SIGTERM SIGINT

# حلقة رئيسية مع تقرير حالة دوري
while true; do
    sleep 60

    # تقرير حالة سريع كل 30 ثانية
    running_count=0
    for pid in "${FFMPEG_PIDS[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            ((running_count++))
        fi
    done

    echo "📊 Status: $running_count/${#FFMPEG_PIDS[@]} streams running"
done
