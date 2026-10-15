#!/usr/bin/env python3
"""Headset-free test client that talks to ros_tcp_endpoint exactly like Unity_Bridge_VR does.

It speaks the Unity ROS-TCP-Connector wire protocol (ROS 2 / CDR flavour, v0.7.x):
    frame = <uint32 len(dest)> <dest utf8> <uint32 len(payload)> <payload>
    sys commands use dest "__publish", "__ros_service", "__request", ... with a JSON payload + NUL.

What it does (mirrors SendControllerData.cs / ToggleTrackingController.cs on Unity main):
  * registers publishers  /xr_input (custom_teleop_messages/XRMod) and /cmd_vel (geometry_msgs/Twist)
  * registers ROS services toggle_tracking / stop_robot (custom_teleop_messages/BoolTrigger)
  * streams XRMod at --rate Hz for --duration s, moving both controllers on a small circle and
    closing the grippers (left/right_squeeze) half-way through
  * optionally calls toggle_tracking once (--call-service) to check the srv type is resolvable

Usage (needs the teleop workspace sourced, because it imports the message classes):
    source ~/teleop_ws/install/setup.bash
    ros2 run ros_tcp_endpoint default_server_endpoint --ros-args -p ROS_IP:=0.0.0.0 -p ROS_TCP_PORT:=10000 &
    python3 fake_unity_client.py --host 127.0.0.1 --port 10000 --duration 10

The poses are in the frame the teleop_msg_bridge expects (it adds left/right_world_trans from
ik_teleop/config/tiago_bridge.yaml and publishes in 'base_link').  This is a plumbing test, not a
calibrated motion: it only proves Unity-format messages reach the IK node and come out as
JointTrajectory commands.
"""
import argparse
import json
import math
import socket
import struct
import threading
import time

from rclpy.serialization import serialize_message
from geometry_msgs.msg import Pose, Twist
from custom_teleop_messages.msg import XRMod

try:
    from custom_teleop_messages.srv import BoolTrigger
except ImportError:  # unpatched custom_teleop_messages (BoolTrigger.srv not generated)
    BoolTrigger = None


def frame(dest: str, payload: bytes) -> bytes:
    d = dest.encode("utf-8")
    return struct.pack("<I", len(d)) + d + struct.pack("<I", len(payload)) + payload


def syscmd(name: str, **params) -> bytes:
    return frame(name, (json.dumps(params) + "\0").encode("utf-8"))


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("endpoint closed the connection")
        buf += chunk
    return buf


def reader(sock, stop):
    """Print what the endpoint sends back (handshake, errors, service responses)."""
    try:
        while not stop.is_set():
            (dlen,) = struct.unpack("<I", recv_exact(sock, 4))
            dest = recv_exact(sock, dlen).decode("utf-8", "replace")
            (plen,) = struct.unpack("<I", recv_exact(sock, 4))
            payload = recv_exact(sock, plen)
            if dest.startswith("__"):
                text = payload.decode("utf-8", "replace").rstrip("\0")
                print(f"[endpoint -> unity] {dest} {text[:300]}", flush=True)
            elif dest:
                print(f"[endpoint -> unity] topic {dest} ({plen} bytes)", flush=True)
    except Exception as e:  # noqa: BLE001
        if not stop.is_set():
            print(f"[reader] stopped: {e}", flush=True)


def pose(x, y, z):
    p = Pose()
    p.position.x, p.position.y, p.position.z = float(x), float(y), float(z)
    p.orientation.w = 1.0
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=10000)
    ap.add_argument("--rate", type=float, default=50.0)
    ap.add_argument("--duration", type=float, default=10.0)
    ap.add_argument("--radius", type=float, default=0.05)
    ap.add_argument("--call-service", action="store_true")
    args = ap.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.settimeout(None)
    stop = threading.Event()
    threading.Thread(target=reader, args=(sock, stop), daemon=True).start()

    sock.sendall(syscmd("__publish", topic="/xr_input",
                        message_name="custom_teleop_messages/XRMod", queue_size=10, latch=False))
    sock.sendall(syscmd("__publish", topic="/cmd_vel",
                        message_name="geometry_msgs/Twist", queue_size=10, latch=False))
    for srv in ("toggle_tracking", "stop_robot"):
        sock.sendall(syscmd("__ros_service", topic=srv,
                            message_name="custom_teleop_messages/BoolTrigger"))
    time.sleep(0.5)

    if args.call_service:
        if BoolTrigger is None:
            print("custom_teleop_messages/srv/BoolTrigger not built - skipping service call")
        else:
            req = BoolTrigger.Request()
            req.trigger = True
            sock.sendall(syscmd("__request", srv_id=1))
            sock.sendall(frame("toggle_tracking", serialize_message(req)))

    t0 = time.time()
    n = 0
    period = 1.0 / args.rate
    while time.time() - t0 < args.duration:
        t = time.time() - t0
        a = 2 * math.pi * 0.25 * t
        msg = XRMod()
        # Rough "operator in front of the robot" poses (metres); bridge adds +0.5 m in x.
        msg.left_controller_pose = pose(0.05 + args.radius * math.cos(a), 0.30 + args.radius * math.sin(a), 0.95)
        msg.right_controller_pose = pose(0.05 + args.radius * math.cos(a), -0.30 - args.radius * math.sin(a), 0.95)
        msg.hmd_pose = pose(0.0, 0.0, 1.45)
        closing = t > args.duration / 2
        msg.left_squeeze = 1.0 if closing else 0.0
        msg.right_squeeze = 1.0 if closing else 0.0
        sock.sendall(frame("/xr_input", serialize_message(msg)))
        sock.sendall(frame("/cmd_vel", serialize_message(Twist())))
        n += 1
        time.sleep(period)

    print(f"sent {n} XRMod messages on /xr_input", flush=True)
    time.sleep(0.5)
    stop.set()
    sock.close()


if __name__ == "__main__":
    main()
