from flask import Flask, Response, request
import requests

app = Flask(__name__)

# حط هنا رابط الـ m3u8 الأصلي (الرابط اللي تبي تعيد بثه)
SOURCE_M3U8 = "http://142.132.133.190:1935/live/Sportchek-ld/chunklist_w1481015368.m3u8"

@app.route("/proxy/<path:path>")
def proxy(path):
    base_url = SOURCE_M3U8.rsplit("/", 1)[0]
    target_url = f"{base_url}/{path}"

    try:
        resp = requests.get(target_url, stream=True, timeout=10)
    except requests.exceptions.RequestException as e:
        return f"خطأ في جلب الملف: {e}", 500

    # إذا كان طلب ملف m3u8، نعدل روابط ts ليتم توجيهها عبر البروكسي نفسه
    if path.endswith(".m3u8"):
        content = resp.content.decode("utf-8")
        # استبدل روابط ts ليتم تحميلها من خلال البروكسي
        content = content.replace(base_url, request.host_url + "proxy")
        return Response(content, content_type=resp.headers.get('Content-Type', 'application/vnd.apple.mpegurl'))

    # ملفات أخرى (مثل .ts)
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
    </body>
    </html>
    """

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
