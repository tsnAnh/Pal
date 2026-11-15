from mcp.server import MCPServer

server = MCPServer("fixture-tools")


@server.tool()
def fixture_echo(text: str) -> str:
    return text


if __name__ == "__main__":
    server.run(transport="stdio")
