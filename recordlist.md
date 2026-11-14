Topic	                                        Msg Type	                                Rate	      
/global_pose	                     geometry_msgs/msg/PoseStamped	                       20 Hz		
/cmd_vel	                           geometry_msgs/msg/Twist	                             20 Hz	   
/joint_states	                     sensor_msgs/msg/JointState	                          20 Hz	        
/points_downsampled_{lidar_id}	   sensor_msgs/msg/PointCloud2	                        1 Hz		
/image_compressed_{cam_id}	         sensor_msgs/msg/CompressedImage	                     1 Hz		
/robot_state                        robot_state.msg                                      20 Hz
/nav_state	                        av_state.msg	                                      20 Hz	        
/motion_state	                     motion_state.msg	                                   20 Hz	        
/manipulation_state	               manipulation_state.msg	                             20 Hz	  
-------------------------------------------------------------------------------------------------------
robot_state.msg:
Code	State Name	                    Explanation (reference,消息定义可按照自身实际情况更改，必须包含所有物理键值引入的状态量)
0	    STOPPED	                急停/人工干预
1	    AUTONOMY	             自主运行模式
2                              运动摇操模式
3                              操作摇操模式
-------------------------------------------------------------------------------------------------------
nav_state.msg:
Code	State Name	                    Explanation (ref)
0	    IDLE	                      导航空闲，未收到导航目标，等待 goal
1	    NAVIGATING	                正常导航，沿有效全局路径行进
2	    REPLANNING	                路径失效，导航模块正在重规划
3	    BLOCKED	                   规划层面阻塞：规划器找不到可行全局路径（≠越障执行失败）
4       ARRIVED	                基座抵达导航目标容差范围内
5	    FAILED	                   导航任务失败：超时、目标不可达、模块异常终止
6	    STOPPED	                   安全急停触发，导航任务暂停
-------------------------------------------------------------------------------------------------------
motion_state.msg:
Code	State Name	                    Explanation (ref)
0	    STANDING	                原地静止站立，无主动运动动作
1	    LOCOMOTING	                正常行进，常规步态运动
2	    ADJUSTING_MOTION	          本体姿态 / 步态调整：含姿态校准、步态切换、准备越障等各类运动预调整
3	    MOTION_EXECUTING	          特殊运动执行中：越障、姿态变换、特殊步态等本体动作执行阶段
4	    MOTION_COMPLETED	          当前目标运动动作执行完成，回归常规运动 / 站立
5	    MOTION_FAILED	             运动执行失败：路径可行，但本体卡滞、姿态失控、动作无法完成
6	    RECOVERING	                卡滞 / 失衡后执行自恢复、姿态复位动作
7	    MANUAL_INTERVENTION	       人工介入干预本体运动，自主运控暂停（除了接管按钮其他失效，如果按下接管开始记录遥控器上所有按钮信息）
-------------------------------------------------------------------------------------------------------
manipulation_state.msg:
Code	State Name	                    Explanation (ref)
0	    MANIP_IDLE	                操作空闲，等待作业指令，机械臂 / 执行器待命
1	    DETECTING_TARGET	          视觉感知搜索作业目标，持续解算 /grasp_object_pose
2	    APPROACHING	             机械臂向作业目标趋近
3	    PRE_OPERATE	             到达预操作位姿，执行器对准目标，准备作业
4	    OPERATING	                执行器动作执行中：夹取、喷射、闭合等作业动作
5	    OPERATE_SUCCESS	          当前作业动作执行成功，状态稳定
6	    OPERATE_FAILED             作业失败：未接触目标、打滑、目标偏移、作业条件不满足
7	    RELEASING	                执行器打开 / 复位，执行释放 / 收尾动作
8	    RELEASE_SUCCESS            目标释放 / 作业收尾完成
9	    MANUAL_INTERVENTION	       人工介入干预臂端操作，自主操作流程暂停
-------------------------------------------------------------------------------------------------------
时间戳约定:
1. 所有带 "std_msgs/Header" 的消息，"header.stamp" 表示采集时刻或状态变更时刻。
   相机填写曝光/取帧时间，雷达填写扫描/帧时间，状态 topic 填写 SDK 状态采样时间。
   对自定义的 "/robot_state"、"/nav_state"、"/motion_state"、"/manipulation_state" 消息，必须包含 "std_msgs/Header header" 并填写 "header.stamp"。
   "/global_pose"、"/joint_states"、点云和压缩图像使用的标准消息已有 Header，也必须正确填写。

2. 自定义状态/动作消息必须包含 "uint64 sequence"，每个新采样递增一次，并在排队/发布前分配。
   每条只增加 8 字节及一次整数递增；20 Hz 状态 topic 的载荷增量约 160 B/s/topic
   若 SDK 自身会丢样，选手还需提供 SDK 采样/丢弃计数。

3. 填写位置是adapter创建每条ROS消息时、调用 "publish()" 之前。
   例如
    C++:"msg.header.stamp = node->get_clock()->now();"
    Python:"msg.header.stamp = node.get_clock().now().to_msg();"
    如果 SDK 给了设备采集时间，应先换算到 ROS 系统时间再赋给 "stamp"；不要把赋值放在 logger/rosbag 侧改写消息。
