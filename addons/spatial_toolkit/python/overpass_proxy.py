"""Run a bounded HTTP request through an HTTP forward or CONNECT proxy."""

import base64
from contextlib import closing
import http.client
import json
import math
import ssl
import sys
from urllib.parse import unquote, urljoin, urlsplit

MAX_INPUT_BYTES = 256 * 1024
MAX_HEADER_BYTES = 128 * 1024
REDIRECT_CODES = {301, 302, 303, 307, 308}
MAX_REDIRECTS = 8
GENERATED_HEADERS = {
    "host", "content-length", "transfer-encoding", "proxy-authorization", "proxy-connection",
}


def reply(status, headers=(), body=b"", *, legacy=False):
    if legacy:
        metadata = str(status).encode("ascii")
    else:
        metadata = json.dumps({"status": status, "headers": headers}, separators=(",", ":")).encode("ascii")
        if len(metadata) > MAX_HEADER_BYTES:
            metadata = b'{"status":"too_large"}'
            body = b""
    sys.stdout.buffer.write(metadata + b"\n")
    sys.stdout.buffer.write(body)


def proxy_address(url):
    proxy = urlsplit(url)
    if (proxy.scheme != "http" or not proxy.hostname or not proxy.port
            or proxy.path not in ("", "/") or proxy.query or proxy.fragment):
        raise ValueError("invalid proxy address")
    headers = {}
    if proxy.username is not None:
        user = unquote(proxy.username)
        password = unquote(proxy.password or "")
        credentials = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
        headers["Proxy-Authorization"] = f"Basic {credentials}"
    return proxy.hostname, proxy.port, headers


def endpoint_address(url):
    endpoint = urlsplit(url)
    if (endpoint.scheme not in ("http", "https") or not endpoint.hostname
            or endpoint.username is not None or endpoint.password is not None
            or endpoint.port == 0):
        raise ValueError("invalid endpoint address")
    return endpoint


def request_headers(raw_headers):
    headers = {"Accept-Encoding": "identity"}
    for header in raw_headers:
        name, separator, value = header.partition(":")
        name = name.strip()
        if not separator or not name:
            raise ValueError("invalid request header")
        if name.lower() not in GENERATED_HEADERS and name.lower() != "accept-encoding":
            headers[name] = value.strip()
    return headers


def open_response(proxy, endpoint, method, headers, body, timeout):
    proxy_host, proxy_port, proxy_headers = proxy
    path = endpoint.path or "/"
    if endpoint.query:
        path += "?" + endpoint.query
    if endpoint.scheme == "https":
        client = http.client.HTTPSConnection(proxy_host, proxy_port, timeout=timeout)
        client.set_tunnel(endpoint.hostname, endpoint.port or 443, headers=proxy_headers)
    else:
        client = http.client.HTTPConnection(proxy_host, proxy_port, timeout=timeout)
        path = "http://" + endpoint.netloc + path
        headers = headers | proxy_headers
    try:
        client.request(method, path, body=body, headers=headers)
        return client, client.getresponse()
    except Exception:
        client.close()
        raise


def request_through_proxy(proxy, url, method, headers, body, timeout, body_limit):
    endpoint = endpoint_address(url)
    for redirect in range(MAX_REDIRECTS + 1):
        try:
            client, response = open_response(proxy, endpoint, method, headers, body, timeout)
        except OSError as error:
            # CONNECT rejection is raised by http.client before a response is exposed.
            if str(error).split()[:4] == ["Tunnel", "connection", "failed:", "407"]:
                return 407, (), b""
            raise
        with closing(client), closing(response):
            if response.status == 407:
                return 407, (), b""
            location = response.getheader("Location")
            if response.status not in REDIRECT_CODES or not location:
                if response.length is not None and response.length > body_limit:
                    return "too_large", (), b""
                data = response.read(body_limit + 1)
                if len(data) > body_limit:
                    return "too_large", (), b""
                if response.length:
                    return "body_mismatch", (), b""
                result_headers = [f"{key}: {value}" for key, value in response.getheaders()]
                return response.status, result_headers, data
            if redirect == MAX_REDIRECTS:
                return "redirect_limit", (), b""
            next_url = urljoin(url, location)
            next_endpoint = endpoint_address(next_url)
            if origin(endpoint) != origin(next_endpoint):
                headers = without_headers(headers, {"authorization", "cookie"})
            if response.status == 303 or (method == "POST" and response.status in (301, 302)):
                method, body = "GET", None
                headers = without_headers(headers, {"content-type", "content-encoding"})
            endpoint, url = next_endpoint, next_url


def origin(endpoint):
    return endpoint.scheme, endpoint.hostname, endpoint.port or (443 if endpoint.scheme == "https" else 80)


def without_headers(headers, names):
    return {key: value for key, value in headers.items() if key.lower() not in names}


def main():
    legacy = False
    try:
        line = sys.stdin.buffer.readline(MAX_INPUT_BYTES + 1)
        if len(line) > MAX_INPUT_BYTES:
            raise ValueError("request exceeds maximum size")
        request = json.loads(line)
        legacy = "url" not in request and "endpoint" in request
        proxy = proxy_address(request["proxy"])
        if legacy:
            url = request["endpoint"]
            if endpoint_address(url).scheme != "https":
                raise ValueError("invalid legacy endpoint")
            method, timeout, body_limit = "POST", 30.0, 16 * 1024 * 1024
            headers = {
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "GodotSpatialToolkit/0.7.0",
            }
        else:
            url, method = request["url"], request["method"]
            timeout, body_limit = float(request["timeout"]), int(request["body_size_limit"])
            if method not in ("GET", "POST") or not math.isfinite(timeout) or timeout <= 0 or body_limit < 0:
                raise ValueError("invalid request settings")
            headers = request_headers(request["headers"])
        body = request["body"].encode("utf-8")
        reply(*request_through_proxy(proxy, url, method, headers,
                                    body if body or method == "POST" else None, timeout, body_limit),
              legacy=legacy)
    except TimeoutError:
        reply("timeout", legacy=legacy)
    except ssl.SSLError:
        reply("tls", legacy=legacy)
    except http.client.IncompleteRead:
        reply("body_mismatch", legacy=legacy)
    except (AttributeError, KeyError, OverflowError, TypeError, ValueError):
        reply("invalid", legacy=legacy)
    except (OSError, http.client.HTTPException):
        reply("connection", legacy=legacy)


if __name__ == "__main__":
    main()
