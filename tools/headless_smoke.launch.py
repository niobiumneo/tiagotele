# Headless teleop smoke test: the ik_teleop pipeline of launch_tiago_ik.py WITHOUT rviz2 and
# WITHOUT Gazebo / a robot. Used by tools/headless_smoke_test.sh.
#
#   robot_state_publisher  (TIAGo Pro URDF: tiago_pro_description/robots/tiago_pro.urdf.xacro, default args)
#   joint_state_publisher  (static /joint_states for every movable joint -> MoveIt gets a complete state)
#   control_node           (name IK_control_node; params = tiago_bio_ik_teleop.yaml + the MoveIt config
#                           built exactly like ik_teleop/launch/launch_tiago_ik.py: SRDF from
#                           ik_teleop/config/tiago_pro.srdf.xacro, ik_teleop kinematics yaml,
#                           tiago_pro_moveit_config controllers / joint_limits / pilz / sensors_3d)
#   teleop_msg_bridge      (name teleop_bridge; tiago_bridge.yaml)
#   gripper_traj_node x2   (gripper_traj_passthrough/launch/tiago_gripper_passthrough.launch.xml)
#
# robot_description_from_topic:=False (default) also passes robot_description as a parameter;
# :=True omits it, exactly like launch_tiago_ik.py (MoveIt then reads the /robot_description topic).
#
#   ros2 launch ./headless_smoke.launch.py [robot_description_from_topic:=True]
import os
from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import Command
from launch_pal.arg_utils import read_launch_argument
from launch_pal.robot_arguments import CommonArgs
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue
from moveit_configs_utils import MoveItConfigsBuilder
from tiago_pro_description.launch_arguments import TiagoProArgs
from tiago_pro_description.tiago_pro_launch_utils import get_tiago_pro_hw_suffix

SRDF_ARGS = ('arm_type_right', 'arm_type_left', 'end_effector_right', 'end_effector_left',
             'ft_sensor_right', 'ft_sensor_left', 'base_type')


def launch_setup(context):
    ik_share = get_package_share_directory('ik_teleop')
    moveit_share = get_package_share_directory('tiago_pro_moveit_config')
    urdf_xacro = os.path.join(get_package_share_directory('tiago_pro_description'),
                              'robots', 'tiago_pro.urdf.xacro')
    robot_description = ParameterValue(Command(['xacro ', urdf_xacro]), value_type=str)

    args = {a: read_launch_argument(a, context) for a in SRDF_ARGS}
    hw_suffix = get_tiago_pro_hw_suffix(
        arm_right=args['arm_type_right'], arm_left=args['arm_type_left'],
        end_effector_right=args['end_effector_right'], end_effector_left=args['end_effector_left'])

    # --- identical to start_move_group() in ik_teleop/launch/launch_tiago_ik.py ---
    moveit_config = (
        MoveItConfigsBuilder('tiago_pro')
        .robot_description_semantic(file_path=Path(ik_share, 'config', 'tiago_pro.srdf.xacro'),
                                    mappings=args)
        .robot_description_kinematics(file_path=os.path.join(ik_share, 'config',
                                                             'tiago_pro_kinematics.yaml'))
        .trajectory_execution(os.path.join(moveit_share,
                                           f'config/controllers/controllers{hw_suffix}.yaml'))
        .joint_limits(file_path=os.path.join(moveit_share, 'config', 'joint_limits.yaml'))
        .planning_pipelines(pipelines=['ompl', 'chomp'], default_planning_pipeline='ompl')
        .planning_scene_monitor({'publish_planning_scene': True,
                                 'publish_geometry_updates': True,
                                 'publish_state_updates': True,
                                 'publish_transforms_updates': True})
        .pilz_cartesian_limits(file_path=os.path.join(moveit_share, 'config',
                                                      'pilz_cartesian_limits.yaml'))
    )
    # launch_tiago_ik.py does `if use_sensor_manager:` on the *string* 'True'/'False', which is
    # always truthy, so it always loads sensors_3d.yaml. Mirror that.
    if read_launch_argument('use_sensor_manager', context):
        moveit_config.sensors_3d(os.path.join(moveit_share, 'config/sensors_3d.yaml'))
    # ------------------------------------------------------------------------------

    control_params = [{'use_sim_time': False},
                      os.path.join(ik_share, 'config', 'tiago_bio_ik_teleop.yaml'),
                      moveit_config.to_dict()]
    if read_launch_argument('robot_description_from_topic', context) not in ('True', 'true', '1'):
        control_params.append({'robot_description': robot_description})

    return [
        Node(package='robot_state_publisher', executable='robot_state_publisher', output='log',
             parameters=[{'robot_description': robot_description}]),
        Node(package='joint_state_publisher', executable='joint_state_publisher', output='log',
             parameters=[{'robot_description': robot_description, 'rate': 50}]),
        Node(package='ik_teleop', executable='control_node', name='IK_control_node',
             output='screen', parameters=control_params),
        Node(package='ik_teleop', executable='teleop_msg_bridge', name='teleop_bridge',
             output='screen',
             parameters=[os.path.join(ik_share, 'config', 'tiago_bridge.yaml')]),
        IncludeLaunchDescription(AnyLaunchDescriptionSource(os.path.join(
            get_package_share_directory('gripper_traj_passthrough'),
            'launch', 'tiago_gripper_passthrough.launch.xml'))),
    ]


def generate_launch_description():
    return LaunchDescription([
        TiagoProArgs.arm_type_right, TiagoProArgs.arm_type_left,
        TiagoProArgs.end_effector_right, TiagoProArgs.end_effector_left,
        TiagoProArgs.ft_sensor_right, TiagoProArgs.ft_sensor_left, TiagoProArgs.base_type,
        CommonArgs.use_sensor_manager,
        DeclareLaunchArgument('robot_description_from_topic', default_value='False',
                              choices=['True', 'False', 'true', 'false'],
                              description='True: do not pass robot_description to control_node '
                                          '(like launch_tiago_ik.py; read from the topic)'),
        OpaqueFunction(function=launch_setup),
    ])
