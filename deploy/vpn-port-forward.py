#!/usr/bin/env python3
"""Forward VPN-facing ports to loopback services.

Listens on the OpenVPN client address (10.8.0.6) and relays each TCP
connection to the same port on 127.0.0.1, where Docker publishes ignis
(8880) and obsidian-mcp (8811).
"""

import asyncio
import logging
import signal

LISTEN_HOST = "10.8.0.6"
TARGET_HOST = "127.0.0.1"
PORT_MAP = {
    8880: 8880,  # ignis web UI
    8811: 8811,  # obsidian-mcp streamable HTTP
}
BUFFER_SIZE = 65536
CONNECT_TIMEOUT = 5.0


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(BUFFER_SIZE)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, TimeoutError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    target_port: int,
) -> None:
    peer = client_writer.get_extra_info("peername")
    try:
        target_reader, target_writer = await asyncio.wait_for(
            asyncio.open_connection(TARGET_HOST, target_port),
            timeout=CONNECT_TIMEOUT,
        )
    except Exception as exc:
        logging.warning("connect to %s:%d failed for %s: %s", TARGET_HOST, target_port, peer, exc)
        client_writer.close()
        return

    await asyncio.gather(
        pump(client_reader, target_writer),
        pump(target_reader, client_writer),
    )


async def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    servers = []
    for listen_port, target_port in PORT_MAP.items():
        server = await asyncio.start_server(
            lambda r, w, p=target_port: handle(r, w, p),
            host=LISTEN_HOST,
            port=listen_port,
            reuse_address=True,
        )
        servers.append(server)
        logging.info(
            "forwarding %s:%d -> %s:%d", LISTEN_HOST, listen_port, TARGET_HOST, target_port
        )

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    await stop.wait()

    for server in servers:
        server.close()
    await asyncio.gather(*(server.wait_closed() for server in servers), return_exceptions=True)


if __name__ == "__main__":
    asyncio.run(main())
