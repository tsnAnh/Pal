import os

_FAKE = os.environ.get("PAL_TEST_FAKE_DISCORD")

if _FAKE:
    import socket

    import discord.gateway
    import discord.http
    import httpx
    import yarl

    _send = httpx.Client.send
    _async_send = httpx.AsyncClient.send
    _resolve = socket.getaddrinfo

    def _redirect(request):
        if request.url.host == "discord.com":
            target = httpx.URL(_FAKE)
            request.url = request.url.copy_with(scheme=target.scheme, host=target.host, port=target.port)

    def _redirected(self, request, *args, **kwargs):
        _redirect(request)
        return _send(self, request, *args, **kwargs)

    async def _async_redirected(self, request, *args, **kwargs):
        _redirect(request)
        return await _async_send(self, request, *args, **kwargs)

    def _loopback_discord(host, *args, **kwargs):
        if str(host).rstrip(".").endswith(("discord.com", "discord.gg", "discordapp.com", "discordapp.net")):
            raise socket.gaierror(f"test refused to resolve {host}")
        return _resolve(host, *args, **kwargs)

    httpx.Client.send = _redirected
    httpx.AsyncClient.send = _async_redirected
    socket.getaddrinfo = _loopback_discord
    discord.http.Route.BASE = _FAKE + "/api/v10"
    discord.gateway.DiscordWebSocket.DEFAULT_GATEWAY = yarl.URL(_FAKE.replace("http", "ws", 1) + "/gateway")
