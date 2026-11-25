"""Send an HTTPS Overpass request through an HTTP CONNECT proxy."""
import base64
from contextlib import closing
import http.client
import json
import socket
import ssl
import sys
from urllib.parse import unquote, urlsplit

BODY_LIMIT = 16 * 1024 * 1024


def reply(status, body=b""):
    sys.stdout.buffer.write(f"{status}\n".encode("ascii") + body)


def main():
    try:
        request = json.loads(sys.stdin.buffer.readline(65536))
        proxy = urlsplit(request["proxy"])
        endpoint = urlsplit(request["endpoint"])
        if (proxy.scheme != "http" or not proxy.hostname or not proxy.port
                or proxy.path not in ("", "/") or proxy.query or proxy.fragment
                or endpoint.scheme != "https" or not endpoint.hostname):
            reply("invalid")
            return
        headers = {}
        if proxy.username is not None:
            user = unquote(proxy.username)
            password = unquote(proxy.password or "")
            credentials = base64.b64encode(f"{user}:{password}".encode()).decode("ascii")
            headers["Proxy-Authorization"] = f"Basic {credentials}"
        with closing(http.client.HTTPSConnection(proxy.hostname, proxy.port, timeout=30)) as client:
            client.set_tunnel(endpoint.hostname, endpoint.port or 443, headers=headers)
            path = endpoint.path or "/"
            if endpoint.query:
                path += "?" + endpoint.query
            client.request("POST", path, body=request["body"], headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "GodotSpatialToolkit/0.7.0",
            })
            response = client.getresponse()
            data = response.read(BODY_LIMIT + 1)
            reply(response.status, data) if len(data) <= BODY_LIMIT else reply("too_large")
    except (ValueError, KeyError, TypeError):
        reply("invalid")
    except (TimeoutError, socket.timeout):
        reply("timeout")
    except ssl.SSLError:
        reply("tls")
    except (OSError, http.client.HTTPException) as error:
        reply(407 if str(error).startswith("Tunnel connection failed: 407 ") else "connection")


if __name__ == "__main__":
    main()
