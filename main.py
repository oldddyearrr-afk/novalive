from flask import Flask, Response, request
import requests

app = Flask(__name__)

# ضع هنا رابط m3u8 الأصلي
SOURCE_M3U8 = "http://142.132.133.190:1935/live/Sportchek-ld/chunklist_w1481015368.m3u8"

@app.route("/proxy/<path:path>")
def proxy(path):
    base_url = SOURCE_M3U8.rsplit("/", 1)[0]
    target_url = f"{base_url}/{path}"

    try:
        resp = requests.get(target_url, stream=True, timeout=10)
        resp.raise_for_status()
    except requests.exceptions.RequestException as e:
        return f"خطأ في جلب الملف: {e}", 500

    # إذا كان الملف m3u8، عدل روابط ts لتوجيهها عبر البروكسي
    if path.endswith(".m3u8"):
        content = resp.content.decode("utf-8")
        # استبدل روابط ts لتستخدم البروكسي نفسه
        content = content.replace(base_url, request.host_url + "proxy")
        return Response(content, content_type="application/vnd.apple.mpegurl")

    # ملفات ts أو أي ملفات أخرى
    return Response(resp.iter_content(chunk_size=8192), content_type=resp.headers.get('Content-Type', 'application/octet-stream'))

@app.route("/")
def index():
    # رابط البث النهائي للمستخدم
    proxy_url = request.host_url + "proxy/" + SOURCE_M3U8.rsplit("/", 1)[-1]
    return f"""
    <html>
    <head><title>HLS Proxy</title></head>
    <body>
        <h2>رابط البث عبر البروكسي:</h2>
        <a href="{proxy_url}" target="_blank">{proxy_url}</a>
        <p>يمكنك استخدام الرابط مباشرة على VLC أو أي مشغل يدعم HLS</p>
    </body>
    </html>
    """

if __name__ == "__main__":
    # Render يفضل استخدام host="0.0.0.0" و port من env
    import os
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port)
