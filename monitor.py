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

# 视频格式后缀列表
video_ext_str = os.environ.get(
    'VIDEO_EXTENSIONS', 
    'mp4,mkv,avi,wmv,mov,ts,rmvb,webm,flv,f4v,m4v,mpg,mpeg,vob,m2ts,mts,3gp,rm,asf,ogv,mxf,dat'
)

# 解析视频格式扩展名
video_extensions_list = []
for ext in video_ext_str.split(','):
    ext = ext.strip().lower()
    if ext:
        if not ext.startswith('.'):
            ext = '.' + ext
        if ext not in video_extensions_list:
            video_extensions_list.append(ext)
video_extensions = tuple(video_extensions_list)

# 磁盘剩余空间保护阈值（GB）
min_free_space_gb = float(os.environ.get('MIN_FREE_SPACE_GB', 10.0))
DOWNLOAD_DIR = '/data/downloads'

# 新增：是否自动恢复“文件丢失/错误”的种子（针对外部 Rclone 抽走文件的场景）
# 默认设为 true，自动开启此功能
auto_resume_missing = os.environ.get('AUTO_RESUME_MISSING', 'true').lower() == 'true'

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
        logging.info(f"Video-only download mode is ENABLED. Allowed extensions: {','.join(video_extensions)}")
        
    if min_free_space_gb > 0:
        logging.info(f"Disk space protection is ENABLED. Will pause downloads if free space drops below {min_free_space_gb} GB.")
        
    if auto_resume_missing:
        logging.info("Auto-resume missing/error torrents is ENABLED. Perfect for external Rclone pulling.")

    state = load_state()

    while True:
        try:
            # ==== 步骤 0. 磁盘空间保护监控 ====
            if min_free_space_gb > 0:
                usage = shutil.disk_usage(DOWNLOAD_DIR)
                free_gb = usage.free / (1024 ** 3)
                
                if free_gb < min_free_space_gb:
                    logging.warning(f"[Disk Alert] Free space ({free_gb:.2f} GB) is below the minimum threshold ({min_free_space_gb} GB)!")
                    downloading = qbt_client.torrents_info(status_filter='downloading')
                    if downloading:
                        hashes = [t.hash for t in downloading]
                        logging.info(f"Pausing {len(hashes)} active torrent(s) to prevent disk full.")
                        qbt_client.torrents_pause(torrent_hashes=hashes)
                        
                        state['auto_paused_due_to_disk'] = list(set(state.get('auto_paused_due_to_disk', []) + hashes))
                        save_state(state)
                    
                    time.sleep(scan_interval)
                    continue 
                
                elif 'auto_paused_due_to_disk' in state and state['auto_paused_due_to_disk']:
                    logging.info(f"[Disk Safe] Free space ({free_gb:.2f} GB) is sufficient. Resuming {len(state['auto_paused_due_to_disk'])} previously paused torrents.")
                    qbt_client.torrents_resume(torrent_hashes=state['auto_paused_due_to_disk'])
                    state['auto_paused_due_to_disk'] = []
                    save_state(state)
            # ==================================

            all_torrents = qbt_client.torrents_info()
            for torrent in all_torrents:
                
                # ==== 步骤 0.5 自动恢复外部拉取导致的报错 ====
                # 当外部 Rclone 删除了文件，qBittorrent 会报 'error' 或 'missingFiles'
                if auto_resume_missing and torrent.state in ['error', 'missingFiles']:
                    logging.info(f"[{torrent.name}] Detected state '{torrent.state}' (likely files moved by external Rclone). Auto-resuming to continue pipeline...")
                    qbt_client.torrents_resume(torrent_hashes=torrent.hash)
                    # 发送恢复指令后，跳过当前种子的后续逻辑，等待下一轮扫描状态刷新后再处理排队
                    continue

                if torrent.progress >= 1.0:
                    continue
                
                if torrent.state == 'metaDL':
                    continue

                files = qbt_client.torrents_files(torrent_hash=torrent.hash)
                
                # ==== 步骤1. 收尾处理 ====
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
