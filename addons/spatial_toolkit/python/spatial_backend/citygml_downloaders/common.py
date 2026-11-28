"""Shared transport and bounded progress for pinned CityGML downloads."""

from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, build_opener


class _HttpsOnlyRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https":
            raise ValueError("The CityGML provider redirected away from HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = build_opener(_HttpsOnlyRedirect())


def open_https(request, *, timeout):
    if urlsplit(request.full_url).scheme != "https":
        raise ValueError("A CityGML provider must use HTTPS")
    return _OPENER.open(request, timeout=timeout)


class Progress:
    """Report a phase at most once per percent with the original units."""

    def __init__(self, callback, phase, total):
        self._callback = callback
        self._phase = phase
        self._total = total
        self._done = 0
        self._percent = -1
        self.advance(0)

    def advance(self, amount):
        self._done += amount
        if self._callback is None:
            return
        percent = self._done * 100 // self._total
        if percent != self._percent:
            self._percent = percent
            self._callback(self._phase, self._done, self._total)
