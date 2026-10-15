import sys, time, rclpy
from rclpy.node import Node
from trajectory_msgs.msg import JointTrajectory
from geometry_msgs.msg import PoseStamped
from std_msgs.msg import Float32
from custom_teleop_messages.msg import XRMod
topics = {'/xr_input': XRMod, '/left_arm_cmd': PoseStamped, '/right_arm_cmd': PoseStamped, '/head_cmd': PoseStamped,
          '/grip/left': Float32, '/grip/right': Float32, '/arm_left_controller/joint_trajectory': JointTrajectory,
          '/arm_right_controller/joint_trajectory': JointTrajectory, '/torso_controller/joint_trajectory': JointTrajectory,
          '/head_controller/joint_trajectory': JointTrajectory, '/gripper_left_controller/joint_trajectory': JointTrajectory,
          '/gripper_right_controller/joint_trajectory': JointTrajectory}
rclpy.init(); n = Node('topic_counter'); counts = {k: 0 for k in topics}; last = {}; prange = {}
def mk(t):
    def cb(m):
        counts[t] += 1; last[t] = m
        if 'gripper' in t and m.points:  # min/max commanded finger position over the whole run
            lo, hi = prange.get(t, (float('inf'), float('-inf')))
            prange[t] = (min(lo, *m.points[-1].positions), max(hi, *m.points[-1].positions))
    return cb
subs = [n.create_subscription(T, t, mk(t), 10) for t, T in topics.items()]
end = time.time() + float(sys.argv[1])
while time.time() < end: rclpy.spin_once(n, timeout_sec=0.1)
for t in topics: print(f'{counts[t]:6d}  {t}')
for t in ['/arm_left_controller/joint_trajectory', '/gripper_left_controller/joint_trajectory', '/torso_controller/joint_trajectory']:
    if t in last:
        m = last[t]; print(t, 'joints=', list(m.joint_names), 'pos=', [round(p, 3) for p in m.points[-1].positions] if m.points else None)
for t, (lo, hi) in prange.items(): print(f'gripper_range {lo:.4f} {hi:.4f} {t}')
