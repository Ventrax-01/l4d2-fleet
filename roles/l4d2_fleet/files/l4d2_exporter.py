#!/usr/bin/env python3
"""Prometheus exporter for a fleet of L4D2 (Source engine) servers.

Queries each server over the Steam A2S protocol and exposes per-instance
metrics, labelled by instance and port:

    l4d2_up{instance,port}            1 if the server answered A2S, else 0
    l4d2_players{instance,port}       current player count
    l4d2_max_players{instance,port}   slot count
    l4d2_bots{instance,port}          bot count
    l4d2_map_info{instance,port,map}  1 (carries the current map as a label)

Configuration comes from the environment (see fleet.env):

    PORT_BASE      base game port; server #N runs on PORT_BASE + N   (default 6032)
    SERVER_COUNT   number of servers to scrape                       (default 4)
    GAME_IP        A2S target; if empty, the host's primary IP is auto-detected
                   (srcds does not reliably answer A2S on 127.0.0.1)
    EXPORTER_PORT  HTTP port to expose /metrics on                   (default 9101)
"""
import http.server
import os
import socket


def primary_ip() -> str:
    """Best-effort detection of the host's primary outbound IPv4 address."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


GAME_IP = os.environ.get("GAME_IP") or primary_ip()
PORT_BASE = int(os.environ.get("PORT_BASE", "6032"))
SERVER_COUNT = int(os.environ.get("SERVER_COUNT", "4"))
LISTEN_PORT = int(os.environ.get("EXPORTER_PORT", "9101"))
SERVERS = {n: PORT_BASE + n for n in range(1, SERVER_COUNT + 1)}

A2S_INFO = b"\xFF\xFF\xFF\xFF\x54Source Engine Query\x00"


def query(port: int) -> dict:
    """Return server info for a single instance, or {'up': 0} if unreachable."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    try:
        s.sendto(A2S_INFO, (GAME_IP, port))
        data, _ = s.recvfrom(4096)
        if data[4:5] == b"\x41":  # challenge — resend with the token appended
            s.sendto(A2S_INFO + data[5:9], (GAME_IP, port))
            data, _ = s.recvfrom(4096)
        if data[4:5] == b"\x49":  # S2A_INFO reply
            rest = data[6:]

            def read_str(buf):
                i = buf.index(0)
                return buf[:i].decode("utf-8", "replace"), buf[i + 1:]

            _name, rest = read_str(rest)
            mapn, rest = read_str(rest)
            _folder, rest = read_str(rest)
            _game, rest = read_str(rest)
            # rest: appid (2 bytes), players, max_players, bots
            return {"up": 1, "players": rest[2], "max": rest[3], "bots": rest[4], "map": mapn}
    except Exception:
        pass
    finally:
        s.close()
    return {"up": 0}


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        up, players, maxp, bots, infos = [], [], [], [], []
        for inst, port in sorted(SERVERS.items()):
            m = query(port)
            lbl = 'instance="%d",port="%d"' % (inst, port)
            up.append("l4d2_up{%s} %d" % (lbl, m["up"]))
            if m["up"]:
                players.append("l4d2_players{%s} %d" % (lbl, m["players"]))
                maxp.append("l4d2_max_players{%s} %d" % (lbl, m["max"]))
                bots.append("l4d2_bots{%s} %d" % (lbl, m["bots"]))
                safe_map = m["map"].replace("\\", "").replace('"', "")
                infos.append('l4d2_map_info{%s,map="%s"} 1' % (lbl, safe_map))
        body = "\n".join(
            ["# TYPE l4d2_up gauge"] + up
            + ["# TYPE l4d2_players gauge"] + players
            + ["# TYPE l4d2_max_players gauge"] + maxp
            + ["# TYPE l4d2_bots gauge"] + bots
            + infos
        ) + "\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args):  # silence per-request logging
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), MetricsHandler).serve_forever()
