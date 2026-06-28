#!/usr/bin/env python3
"""Minimal OpenSnitch UI client that logs unmatched connections.

The daemon is the gRPC *client*: it dials the UI server configured in
default-config.json (Server.Address, default unix:///tmp/osui.sock). Any
connection that matches no rule is a novel flow, so the daemon calls AskRule
on us. This server answers with the daemon's configured default
(DefaultAction/DefaultDuration, learned from the Subscribe config) and logs
each asked-about connection.

No build step: reuses the stubs shipped by python3-opensnitch-ui.

Usage:
    python3 observer.py [--socket unix:///tmp/osui.sock] [--log FILE] [--all]
"""

import argparse
import collections
import json
import os
import sys
import threading
import time
from concurrent import futures
from datetime import datetime

import grpc

sys.path.append("/usr/lib/python3/dist-packages")
from opensnitch import ui_pb2, ui_pb2_grpc

CONFIG_PATHS = (
    "/etc/opensnitchd/default-config.json",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "default-config.json"),
)
FALLBACK_ACTION = "reject"
FALLBACK_DURATION = "1h"


def read_defaults_from_config():
    """Best-effort DefaultAction/DefaultDuration from a daemon config file."""
    for path in CONFIG_PATHS:
        try:
            with open(path) as fh:
                cfg = json.load(fh)
            return (cfg.get("DefaultAction"), cfg.get("DefaultDuration"))
        except (OSError, ValueError):
            continue
    return (None, None)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--socket", default="unix:///tmp/osui.sock",
                   help="address the daemon dials (matches Server.Address)")
    p.add_argument("--log", default=None,
                   help="append log lines to this file (default: stdout)")
    p.add_argument("--all", action="store_true",
                   help="also log every Ping event, not just AskRule prompts")
    return p.parse_args()


class Logger:
    def __init__(self, path):
        self._fh = open(path, "a", buffering=1) if path else sys.stdout

    def write(self, line):
        self._fh.write(line + "\n")
        if self._fh is not sys.stdout:
            pass  # line-buffered append; flush implied by buffering=1


class UIService(ui_pb2_grpc.UIServicer):
    def __init__(self, logger, log_all):
        self._log = logger
        self._log_all = log_all
        # bounded dedup: events arrive repeatedly in the rolling stats buffer
        self._seen = collections.OrderedDict()
        self._seen_max = 4096
        # daemon defaults, learned in Subscribe; seeded from config files
        action, duration = read_defaults_from_config()
        self._default_action = action or FALLBACK_ACTION
        self._default_duration = duration or FALLBACK_DURATION

    def _already_seen(self, key):
        if key in self._seen:
            return True
        self._seen[key] = None
        if len(self._seen) > self._seen_max:
            self._seen.popitem(last=False)
        return False

    def _format(self, ev):
        return self._format_conn(ev.connection, ev.rule.action, ev.rule.name,
                                 ev.time or None)

    def _format_conn(self, c, action, rule_name, when=None):
        dst = c.dst_host or c.dst_ip
        args = " ".join(c.process_args) if c.process_args else c.process_path
        when = when or datetime.now().isoformat(timespec="seconds")
        return (f"{when} {action:6s} rule={rule_name} "
                f"{c.protocol} {c.src_ip}:{c.src_port}->{dst}:{c.dst_port} "
                f"uid={c.user_id} pid={c.process_id} {args}")

    def Ping(self, request, context):
        # Novel flows are logged in AskRule; only mirror Ping events with --all.
        if not self._log_all:
            return ui_pb2.PingReply(id=request.id)
        for ev in request.stats.events:
            key = ev.unixnano or hash(ev.SerializeToString())
            if self._already_seen(key):
                continue
            self._log.write(self._format(ev))
        return ui_pb2.PingReply(id=request.id)

    def AskRule(self, request, context):
        # Daemon prompts here for any connection that matched no rule.
        # Answer with the configured default and log the asked-about flow.
        c = request
        action = self._default_action
        host = c.dst_host or c.dst_ip
        operand = "dest.host" if c.dst_host else "dest.ip"
        self._log.write(self._format_conn(c, action, f"observer-{action}"))
        return ui_pb2.Rule(
            name=f"observer-{action}",
            enabled=True,
            action=action,
            duration=self._default_duration,
            operator=ui_pb2.Operator(type="simple", operand=operand, data=host),
        )

    def Subscribe(self, node_config, context):
        try:
            cfg = json.loads(node_config.config) if node_config.config else {}
            self._default_action = cfg.get("DefaultAction") or self._default_action
            self._default_duration = cfg.get("DefaultDuration") or self._default_duration
        except ValueError:
            pass
        self._log.write(f"# daemon connected: {context.peer()} "
                        f"({node_config.name} {node_config.version}) "
                        f"default={self._default_action}/{self._default_duration}")
        return node_config

    def Notifications(self, request_iterator, context):
        # Keep the stream open; drain daemon->UI messages, send none back.
        def drain():
            try:
                for _ in request_iterator:
                    pass
            except Exception:
                pass
        threading.Thread(target=drain, daemon=True).start()
        while context.is_active():
            time.sleep(0.5)
        return
        yield  # mark as generator (stream response)


def socket_to_bind(addr):
    if addr.startswith("unix://"):
        path = addr[len("unix://"):]
        if path.startswith("/") and not path.startswith("//"):
            pass  # unix:///abs -> /abs already
        path = "/" + path.lstrip("/")
        if os.path.exists(path):
            os.unlink(path)
        return f"unix:{path}"
    return addr


def main():
    args = parse_args()
    logger = Logger(args.log)
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    ui_pb2_grpc.add_UIServicer_to_server(UIService(logger, args.all), server)
    bind = socket_to_bind(args.socket)
    server.add_insecure_port(bind)
    server.start()
    logger.write(f"# observer listening on {bind} "
                 f"(logging: {'AskRule + all Ping events' if args.all else 'AskRule prompts'})")
    try:
        server.wait_for_termination()
    except KeyboardInterrupt:
        server.stop(0)


if __name__ == "__main__":
    main()
