#!/usr/bin/env python3
import time
import os
import json
import qbittorrentapi
import logging
import shutil

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

qbt_port = int(os.environ.get('QBT_INTERNAL_PORT', 18080))
scan_interval = int(os.environ.get('MONITOR_INTERVAL', 60))
max_concurrent_files = int(os.environ.get('MAX_CONCURRENT_FILES', 0))

# 是否只下载视频文件的开关
only_video_files = os.environ.get('ONLY_VIDEO_FILES', 'false').lower() == 'true'
video_ext_str = os.environ.get('VIDEO_EXTENSIONS', '.mp4,.mkv,.avi,.rmvb,.flv,.mov,.wmv,.ts,.webm,.iso')
video_extensions = tuple(ext.strip().lower() for ext in video_ext_str.split(',') if ext.strip())

# 新增：磁盘剩余空间保护阈值（GB）。设为 0 则关闭此功能。
# 你的服务器是100G，占用90G也就是剩余10G，这里默认设为 10.0
min_free_space_gb = float(os.environ.get('MIN_FREE_SPACE_GB', 10.0))
DOWNLOAD_DIR = '/data/downloads'

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
        logging.info("Concurrent file limit is DISABLED.")

    if only_video_files:
        logging.info(f"Video-only download mode is ENABLED. Allowed extensions: {video_extensions}")
        
    if min_free_space_gb > 0:
        logging.info(f"Disk space protection is ENABLED. Will pause downloads if free space drops below {min_free_space_gb} GB.")

    state = load_state()

    while True:
        try:
            # ==== 步骤 0. 磁盘空间保护监控 ====
            if min_free_space_gb > 0:
                # 获取下载目录所在磁盘的使用情况
                usage = shutil.disk_usage(DOWNLOAD_DIR)
                free_gb = usage.free / (1024 ** 3)
                
                if free_gb < min_free_space_gb:
                    logging.warning(f"[Disk Alert] Free space ({free_gb:.2f} GB) is below the minimum threshold ({min_free_space_gb} GB)!")
                    # 获取正在下载的种子
                    downloading = qbt_client.torrents_info(status_filter='downloading')
                    if downloading:
                        hashes = [t.hash for t in downloading]
                        logging.info(f"Pausing {len(hashes)} active torrent(s) to prevent disk full.")
                        qbt_client.torrents_pause(torrent_hashes=hashes)
                        
                        # 记录被脚本自动暂停的种子，以便空间释放后恢复
                        state['auto_paused_due_to_disk'] = list(set(state.get('auto_paused_due_to_disk', []) + hashes))
                        save_state(state)
                    
                    time.sleep(scan_interval)
                    continue # 空间不足时，暂停后直接跳过后续的排队与状态检查逻辑，直到空间释放
                
                elif 'auto_paused_due_to_disk' in state and state['auto_paused_due_to_disk']:
                    # 如果空间恢复正常，且存在被脚本暂停的种子，则恢复它们
                    logging.info(f"[Disk Safe] Free space ({free_gb:.2f} GB) is sufficient. Resuming {len(state['auto_paused_due_to_disk'])} previously paused torrents.")
                    qbt_client.torrents_resume(torrent_hashes=state['auto_paused_due_to_disk'])
                    state['auto_paused_due_to_disk'] = []
                    save_state(state)
            # ==================================

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
                        if file.priority != 0 and file.progress < 1.0:
                            _, ext = os.path.splitext(file.name)
                            if ext.lower() not in video_extensions:
                                non_video_ids.append(file.index)
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
                    if hash_key not in state:
                        state[hash_key] = {}
                        for file in files:
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
                                state[hash_key][str(file.index)] = 'ignored'
                    
                    active_files_indices = [f.index for f in files if f.priority != 0 and f.progress < 1.0]

                    if len(active_files_indices) < max_concurrent_files:
                        slots_available = max_concurrent_files - len(active_files_indices)
                        
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
                            for fid in to_start:
                                state[hash_key][str(fid)] = 'downloading'
            
            save_state(state)

        except Exception as e:
            logging.error(f"Error checking torrents: {e}")
            
        time.sleep(scan_interval)

if __name__ == '__main__':
    logging.info(f"Starting qBittorrent file monitor with a {scan_interval}s interval...")
    monitor_torrents()
