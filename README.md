# RobotLogger Recorder（选手发布包）
本包只包含官方侧的ROS2 topic检查、rosbag2录制和录后审计工具。选手负责实现并运行 adapter，按 "recordlist.md" 发布约定的ROS2 topics

## 目录
robotlogger-recorder/
├── README.md
├── recordlist.md
├── deployment/
│   ├── robotlogger.sh
│   └── topics.regex
└── tools/
    └── audit_bag.py
请保留目录结构：录制脚本按相对路径读取 topic 白名单，录后审计也会调用 "tools/audit_bag.py"。

## 环境要求
- x86_64 Linux机器人，已安装并能运行ROS2和rosbag2。
- 机器人adapter已启动，并按recordlist.md发布topic。
- 如使用自定义ROS消息，消息接口包需为机器人正在使用的ROS2发行版构建并安装；首次检查时按提示提供它的install/setup.bash路径。
- SSD已挂载。若录制目录没有写权限，脚本会提示使用sudo。

## 检查与录制
将整个robotlogger-recorder目录复制到SSD，例如"/mnt/robot-ssd/robotlogger-recorder"，然后运行：
cd /mnt/robot-ssd/robotlogger-recorder
deployment/robotlogger.sh check
deployment/robotlogger.sh

脚本会发现ROS2安装和可用的RMW，检查SSD、空间和合同topic，如果ROS发行版、DDS domain、SSD挂载位置或自定义接口路径无法唯一判断，会在终端说明并提示补充。补充项保存在当前用户的 `~/.config/robotlogger/robotlogger.conf`，下次运行会复用。

固定名称的合同 topic（如 `/cmd_vel`、`/global_pose`）即使尚未启动，也不会让 `check` 失败；rosbag2 会每秒等待并订阅它们。topic 暂停时 bag 保持运行，同名、同类型且 QoS 兼容的 publisher 恢复后会继续收到消息。带设备 ID 的点云/图像 topic 若还未发布，脚本会提示输入完整名称并保存；也可用重复的 `--topic` 参数指定，例如 `deployment/robotlogger.sh record --topic /points_downsampled_mid360 --topic /image_compressed_front`。如果迟启动的状态 topic 使用自定义消息类型，首次提示时提供 adapter 的 `install/setup.bash`。

默认bag目录为：
<SSD挂载点>/rosbags/<机器人主机名>/<UTC时间>-<进程号>
开始录制后按 "Ctrl-C" 正常结束并等待 rosbag2 完成收尾。
