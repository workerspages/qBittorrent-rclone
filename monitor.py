#!/usr/bin/env python3
import time
import os
import json
import qbittorrentapi
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

qbt_port = int(os.environ.get('QBT_INTERNAL_PORT', 18080))
scan_interval = int(os.environ.get('MONITOR_INTERVAL', 60))
max_concurrent_files = int(os.environ.get('MAX_CONCURRENT_FILES', 0))

# 新增：是否只下载视频文件的开关环境变量
only_video_files = os.environ.get('ONLY_VIDEO_FILES', 'false').lower() == 'true'
# 新增：自定义识别的视频格式后缀环境变量
video_ext_str = os.environ.get('VIDEO_EXTENSIONS', '.mp4,.mkv,.avi,.rmvb,.flv,.mov,.wmv,.ts,.webm,.iso')
video_extensions = tuple(ext.strip().lower() for ext in video_ext_str.split(',') if ext.strip())

STATE_FILE = '/data/config/qBittorrent/config/monitor_state.json'

conn_info = dict(
    host='127.0.0.1',
    port=qbt_port,
)

qbt_client = qbittorrentapi.Client(**conn_info)

def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_state(state):
    try:
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f)
    except Exception as e:
        logging.error(f"Failed to save state map: {e}")

def monitor_torrents():
    while True:
        try:
            qbt_client.auth_log_in()
            break
        except Exception as e:
            logging.warning(f"Waiting for qBittorrent WebUI to become available... ({e})")
            time.sleep(5)

    logging.info(f"Successfully connected to qBittorrent WebUI.")
    if max_concurrent_files > 0:
        logging.info(f"Concurrent file limit is ENABLED. Max downloading files per torrent: {max_concurrent_files}")
    else:
        logging.info("Concurrent file limit is DISABLED (MAX_CONCURRENT_FILES <= 0).")

    # 打印视频过滤模式状态
    if only_video_files:
        logging.info(f"Video-only download mode is ENABLED. Allowed extensions: {video_extensions}")
    else:
        logging.info("Video-only download mode is DISABLED.")

    state = load_state()

    while True:
        try:
            all_torrents = qbt_client.torrents_info()
            for torrent in all_torrents:
                # 只处理尚未完全下载完成的合集种子
                if torrent.progress >= 1.0:
                    continue
                
                # 若处于下载元数据状态（如刚添加的磁力链接），跳过本次处理
                if torrent.state == 'metaDL':
                    continue

                files = qbt_client.torrents_files(torrent_hash=torrent.hash)
                
                # ==== 步骤1. 收尾处理 (处理已经完成的文件) ====
                file_ids_to_ignore = []
                for file in files:
                    if file.progress >= 1.0 and file.priority != 0:
                        file_ids_to_ignore.append(file.index)
                
                if file_ids_to_ignore:
                    logging.info(f"Found {len(file_ids_to_ignore)} completed files in torrent: '{torrent.name}'. Setting priority to 'Do not download' (0).")
                    qbt_client.torrents_file_priority(
                        torrent_hash=torrent.hash,
                        file_ids=file_ids_to_ignore,
                        priority=0
                    )
                
                # 修改当前内存变量防止下一步将其误识别为活跃
                for file in files:
                    if file.index in file_ids_to_ignore:
                        file.priority = 0

                # ==== 步骤1.5 只下载视频文件过滤 ====
                if only_video_files:
                    non_video_ids = []
                    for file in files:
                        # 只处理还在下载队列中、且未下载完成的文件
                        if file.priority != 0 and file.progress < 1.0:
                            _, ext = os.path.splitext(file.name)
                            if ext.lower() not in video_extensions:
                                non_video_ids.append(file.index)
                                # 修改内存变量，防止被步骤2误识别为待下载文件
                                file.priority = 0 
                                
                    if non_video_ids:
                        logging.info(f"[{torrent.name}] Found {len(non_video_ids)} non-video files. Setting priority to 'Do not download' (0).")
                        qbt_client.torrents_file_priority(
                            torrent_hash=torrent.hash,
                            file_ids=non_video_ids,
                            priority=0
                        )

                # ==== 步骤2. 并发下载排队控制算法 ====
                if max_concurrent_files > 0:
                    hash_key = torrent.hash
                    # 初次捕获：锁定用户最初期望挂载的真实下载意愿
                    if hash_key not in state:
                        state[hash_key] = {}
                        for file in files:
                            # 如果该文件意图下载且没下完，我们暂定它为 pending，并阻止它抢网速
                            if file.priority != 0 and file.progress < 1.0:
                                state[hash_key][str(file.index)] = 'pending'
                                qbt_client.torrents_file_priority(
                                    torrent_hash=hash_key,
                                    file_ids=[file.index],
                                    priority=0
                                )
                                file.priority = 0
                            elif file.progress >= 1.0:
                                state[hash_key][str(file.index)] = 'completed'
                            else:
                                state[hash_key][str(file.index)] = 'ignored' # 本来就是不下载的文件（用户手动略过或非视频文件）
                    
                    # 计算在途正在真机抢带宽的核心活跃文件
                    active_files_indices = [f.index for f in files if f.priority != 0 and f.progress < 1.0]

                    # 存在多余连接空余的话，开闸发车！
                    if len(active_files_indices) < max_concurrent_files:
                        slots_available = max_concurrent_files - len(active_files_indices)
                        
                        # 挑选需要补充的 pending 文件按索引先后
                        pending_files = []
                        for file in files:
                            if state[hash_key].get(str(file.index)) == 'pending' and file.priority == 0 and file.progress < 1.0:
                                pending_files.append(file.index)

                        if pending_files:
                            to_start = pending_files[:slots_available]
                            logging.info(f"[{torrent.name}] Concurrency slot open: resuming {len(to_start)} pending file(s): indexes {to_start}")
                            
                            qbt_client.torrents_file_priority(
                                torrent_hash=hash_key,
                                file_ids=to_start,
                                priority=1
                            )
                            # 从等待池移动到执行池
                            for fid in to_start:
                                state[hash_key][str(fid)] = 'downloading'
            
            save_state(state)

        except Exception as e:
            logging.error(f"Error checking torrents: {e}")
            
        time.sleep(scan_interval)

if __name__ == '__main__':
    logging.info(f"Starting qBittorrent file monitor with a {scan_interval}s interval...")
    monitor_torrents()
