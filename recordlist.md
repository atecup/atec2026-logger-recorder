# ROS 2 录制消息规范

消息类型、字段和单位固定。设备 ID 由选手填写；坐标系、数据来源和数字含义按[数据说明模板](templates/data_description.md)说明，并随 bag 交付。

| Topic | 消息类型 | 录制频率 | 要求 |
|---|---|---|---|
| `/global_pose` | `geometry_msgs/msg/PoseStamped` | 20 Hz | 必填 |
| `/imu/data_raw` | `sensor_msgs/msg/Imu` | 20 Hz | 必填 |
| `/cmd_vel` | `geometry_msgs/msg/Twist` | 20 Hz | 必填 |
| `/joint_states` | `sensor_msgs/msg/JointState` | 20 Hz | 必填 |
| `/points_downsampled_{lidar_id}` | `sensor_msgs/msg/PointCloud2` | 1 Hz | 必填 |
| `/image_compressed_{cam_id}` | `sensor_msgs/msg/CompressedImage` | 1 Hz | 必填 |
| `/robot_state` | `robotlogger_interfaces/msg/RobotState` | 20 Hz | 必填 |
| `/nav_state` | `robotlogger_interfaces/msg/NavState` | 20 Hz | 选填 |
| `/motion_state` | `robotlogger_interfaces/msg/MotionState` | 20 Hz | 选填 |
| `/manipulation_state` | `robotlogger_interfaces/msg/ManipulationState` | 20 Hz | 选填 |

发布频率应不低于录制频率；无新数据时不重复录制。IMU 的 20 Hz 为抽样记录，不完整保留高频振动。

## 通用约定

- `header.stamp` 优先填实际采样时间，无法获取时填 adapter 接收时间并注明；使用机器人系统时间，设备时钟需先换算。bag 写入时间由录制器记录。
- `header.frame_id` 填实际坐标系名称；无适用坐标系的状态消息可为空。坐标原点、轴方向和参考点在数据说明中填写。
- 四元数按 `x/y/z/w` 填写并归一化，无旋转为 `(0,0,0,1)`。

## 数据字段

### `/global_pose`

- `pose.position.x/y/z`：机器人本体全局位置，m。
- `pose.orientation.x/y/z/w`：本体相对于同一全局坐标系的姿态。
- 参考点保持一致；无有效定位时停止发布，不用零值冒充定位结果。

### `/imu/data_raw`

- `linear_acceleration.x/y/z`：三轴线加速度，m/s²，说明是否去除重力。
- `angular_velocity.x/y/z`：三轴角速度，rad/s。
- 不要求姿态，`orientation_covariance[0]` 填 -1；加速度、角速度协方差未知时全填 0。

### `/cmd_vel`

`linear.x/y/z` 为速度指令（m/s），`angular.x/y/z` 为角速度指令（rad/s）；不支持的分量填 0。该消息没有 Header。

### `/joint_states`

- `name`：关节名称，与实际关节的对应关系在数据说明中列出。
- `position`：必填，旋转关节用 rad，移动关节用 m。
- `velocity`、`effort`：选填，单位分别为 rad/s 或 m/s、N·m 或 N；注明 effort 是实测、估算还是指令值。
- 同一条消息对应同一采样时刻；各数值数组与 name 等长，不可用的选填数组留空。

### 点云与图像

- 点云含 `x/y/z` FLOAT32 字段，单位 m；字段定义和数据布局须匹配。
- 压缩图像 `format` 为 `jpeg` 或 `png`，`data` 为对应编码的完整图像。
- 设备 ID 保持稳定，frame_id 对应实际传感器坐标系。

## 状态消息

接口源码位于 `interfaces/robotlogger_interfaces/msg/`。四种消息均含：

```text
std_msgs/Header header
uint64 sequence
uint8 state
```

`sequence` 每次新采样递增，重发旧样本不递增；adapter 重启可归零并在数据说明中注明。

`/robot_state` 表示机器人整体运行状态。`state` 每次填写一个当前整体运行模式，其中 0–3 的含义固定：

| 值 | 含义 |
|---|---|
| 0 | STOPPED：急停／安全停机 |
| 1 | AUTONOMY：自主运行 |
| 2 | MOTION_TELEOP：运动遥控 |
| 3 | MANIPULATION_TELEOP：操作遥控 |

其他整体运行模式可使用 `state = 4–255` 自定义，不能改变 0–3 的含义；扩展数字的含义在 `data_description.md` 中列出，无需修改消息字段。

`status_names` 和 `status_values` 可继续添加其他状态量，包括所有物理按键、开关对应的模式或功能实际状态。例如 `status_names = ["obstacle_avoidance", "speed_mode"]`、`status_values = [1, 2]`，可分别表示避障已开启、速度档位为 2；具体含义由选手说明。

这些状态可同时存在，不记录按键按下/松开或摇杆原始值。每次采样提供完整状态，名称唯一且与数值一一对应；无适用项时两数组留空。扩展项的名称、数值含义及无法获取的状态在数据说明中列出。

`/nav_state`、`/motion_state`、`/manipulation_state` 可不发布；提供时，state 在 0–255 内自定义，并分别说明每个数字的含义。

### 选填状态示例

以下仅为参考，不是固定枚举。选手可增删状态或调整数字，并在 `data_description.md` 中列出实际使用的含义。

**`/nav_state`：导航任务进行到哪个阶段。**

| state 示例 | 含义 |
|---|---|
| 0 | 空闲：等待导航目标 |
| 1 | 导航中：沿规划路径前进 |
| 2 | 重规划：正在重新规划路径 |
| 3 | 阻塞：无法找到可行路径 |
| 4 | 到达目标 |
| 5 | 导航失败：超时、目标不可达等 |
| 6 | 导航暂停／停止 |

**`/motion_state`：本体运动的执行状态。** 导航有路可走，不代表本体一定能成功通过。

| state 示例 | 含义 |
|---|---|
| 0 | 原地站立／静止 |
| 1 | 正常行走 |
| 2 | 运动调整：调整姿态、步态或准备越障 |
| 3 | 特殊运动执行中：越障、姿态变换等 |
| 4 | 当前运动动作完成 |
| 5 | 运动失败：卡滞、失衡、无法通过等 |
| 6 | 自恢复中 |
| 7 | 人工介入运动控制 |

**`/manipulation_state`：机械臂、夹爪等操作任务的执行状态。**

| state 示例 | 含义 |
|---|---|
| 0 | 空闲：等待操作任务 |
| 1 | 识别／搜索操作目标 |
| 2 | 接近目标 |
| 3 | 操作准备：对准、调整姿态等 |
| 4 | 操作中：抓取、按压、喷射等 |
| 5 | 操作成功 |
| 6 | 操作失败 |
| 7 | 释放／收尾中 |
| 8 | 释放／收尾完成 |
| 9 | 人工介入操作控制 |
