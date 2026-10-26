"""Ability Cam を家のLAN内でHTTPS配信する（スマホのブラウザでカメラを使うにはHTTPSが必要）。

使い方:
    python serve.py
    → 表示された https://<PCのIP>:8443 をスマホで開く（同じWi-Fiにつなぐ）
    → 「この接続ではプライバシーが保護されません」等が出たら、詳細から進む（自分で作った証明書のため）

PC単体で試すだけなら、証明書なしで  python -m http.server 8000  →  http://localhost:8000  でも動く。
"""
import http.server, ssl, socket, subprocess, os, sys

PORT = 8443
HERE = os.path.dirname(os.path.abspath(__file__))
CERT, KEY = os.path.join(HERE, "cert.pem"), os.path.join(HERE, "key.pem")


def make_cert():
    if os.path.exists(CERT) and os.path.exists(KEY):
        return
    try:
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", KEY, "-out", CERT, "-days", "30", "-subj", "/CN=ability-cam"],
                       check=True, capture_output=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        sys.exit("証明書を作れませんでした。openssl を入れるか、Git Bash 等から実行してください。")


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))  # 実際には送信しない。自分のLAN側IPを知るため
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


if __name__ == "__main__":
    os.chdir(HERE)
    make_cert()
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), http.server.SimpleHTTPRequestHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"スマホで開く: https://{lan_ip()}:{PORT}")
    print(f"PCで開く:     https://localhost:{PORT}")
    httpd.serve_forever()
