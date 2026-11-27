import os

_FAKE = os.environ.get("PAL_TEST_FAKE_DISCORD")

if _FAKE:
    import discord.gateway
    import discord.http
    import httpx
    import yarl

    _send = httpx.Client.send

    def _redirected(self, request, *args, **kwargs):
        if request.url.host == "discord.com":
            target = httpx.URL(_FAKE)
            request.url = request.url.copy_with(scheme=target.scheme, host=target.host, port=target.port)
        return _send(self, request, *args, **kwargs)

    httpx.Client.send = _redirected
    discord.http.Route.BASE = _FAKE + "/api/v10"
    discord.gateway.DiscordWebSocket.DEFAULT_GATEWAY = yarl.URL(_FAKE.replace("http", "ws", 1) + "/gateway")
