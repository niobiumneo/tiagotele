#!/usr/bin/env python3
"""Publish custom_teleop_messages/msg/XRMod on /xr_input directly over DDS (no Unity, no endpoint).

All three poses are non-zero (teleop_msg_bridge drops a message if ANY of left/right/hmd position
is ~0). Both controllers move on a small circle in front of the robot so the IK keeps producing new
joint targets; the HMD nods slowly; left/right_squeeze ramp 0 -> 1 -> 0.

    python3 xr_input_pub.py [--rate 50] [--duration 10] [--radius 0.06]
"""
import argparse
import math
import time

import rclpy
from geometry_msgs.msg import Pose
from rclpy.node import Node

from custom_teleop_messages.msg import XRMod


def pose(x, y, z, yaw=0.0, pitch=0.0):
    p = Pose()
    p.position.x, p.position.y, p.position.z = float(x), float(y), float(z)
    # ZYX Euler -> quaternion with roll = 0
    cy, sy, cp, sp = math.cos(yaw / 2), math.sin(yaw / 2), math.cos(pitch / 2), math.sin(pitch / 2)
    p.orientation.w = cp * cy
    p.orientation.x = -sp * sy
    p.orientation.y = sp * cy
    p.orientation.z = cp * sy
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rate', type=float, default=50.0)
    ap.add_argument('--duration', type=float, default=10.0)
    ap.add_argument('--radius', type=float, default=0.06)
    a = ap.parse_args()

    rclpy.init()
    node = Node('fake_xr_input')
    pub = node.create_publisher(XRMod, '/xr_input', 10)
    # give discovery a moment so the first messages are not lost
    t_wait = time.time()
    while pub.get_subscription_count() == 0 and time.time() - t_wait < 5.0:
        time.sleep(0.1)

    t0, n, period = time.time(), 0, 1.0 / a.rate
    while time.time() - t0 < a.duration:
        t = time.time() - t0
        w = 2 * math.pi * 0.25 * t
        m = XRMod()
        # operator frame (FLU, metres); the bridge adds +0.5 m x and a 90 deg tool pitch
        m.left_controller_pose = pose(0.05 + a.radius * math.cos(w), 0.30 + a.radius * math.sin(w), 0.95)
        m.right_controller_pose = pose(0.05 + a.radius * math.cos(w), -0.30 - a.radius * math.sin(w), 0.95)
        m.hmd_pose = pose(0.0, 0.0, 1.45, yaw=0.3 * math.sin(w), pitch=0.2 * math.sin(w))
        s = 0.5 - 0.5 * math.cos(2 * math.pi * t / a.duration)   # 0 -> 1 -> 0
        m.left_squeeze = float(s)
        m.right_squeeze = float(s)
        pub.publish(m)
        n += 1
        time.sleep(period)
    print(f'published {n} XRMod messages on /xr_input', flush=True)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
