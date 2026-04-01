#!/usr/bin/env python3
import time
import os
import json
import qbittorrentapi
import logging
import shutil
import base64
import subprocess

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

# ================= 1. 基础配置与视频过滤 =================
qbt_port = int(os.environ.get('QBT_INTERNAL_PORT', 18080))
scan_interval = int(os.environ.get('MONITOR_INTERVAL', 60))
max_concurrent_files = int(os.environ.get('MAX_CONCURRENT_FILES', 0))

only_video_files = os.environ.get('ONLY_VIDEO_FILES', 'false').lower() == 'true'
video_ext_str = os.environ.get(
    'VIDEO_EXTENSIONS', 
    'mp4,mkv,avi,wmv,mov,ts,rmvb,webm,flv,f4v,m4v,mpg,mpeg,vob,m2ts,mts,3gp,rm,asf,ogv,mxf,dat'
)
video_extensions_list = []
for ext in video_ext_str.split(','):
    ext = ext.strip().lower()
    if ext:
        if not ext.startswith('.'):
            ext = '.' + ext
        if ext not in video_extensions_list:
            video_extensions_list.append(ext)
video_extensions = tuple(video_extensions_list)

# ================= 2. 磁盘保护与路线A(外部抽水)配置 =================
min_free_space_gb = float(os.environ.get('MIN_FREE_SPACE_GB', 10.0))
DOWNLOAD_DIR = '/data/downloads'

# 路线 A 核心保障：自动恢复被外部拉走后报错的种子
auto_resume_missing = os.environ.get('AUTO_RESUME_MISSING', 'true').lower() == 'true'

# ================= 3. 路线B(单文件即时上传)配置 =================
rclone_config_b64 = os.environ.get('RCLONE_CONFIG_BASE64', '')
rclone_cmd_template = os.environ.get('RCLONE_CMD', '')

if rclone_config_b64:
    try:
        config_data = base64.b64decode(rclone_config_b64).decode('utf-8')
        config_path = '/tmp/rclone.conf'
        with open(config_path, 'w', encoding='utf-8') as f:
            f.write(config_data)
        os.environ['RCLONE_CONFIG'] = config_path
        logging.info("Successfully decoded RCLONE_CONFIG_BASE64 and initialized Rclone config.")
    except Exception as e:
        logging.error(f"Failed to decode RCLONE_CONFIG_BASE64: {e}")

STATE_FILE = '/data/config/qBittorrent/config/monitor_state.json'

# ================= 增加认证信息，通过环境变量注入密码 =================
qbt_user = os.environ.get('QBT_USER', 'admin')
qbt_pass = os.environ.get('QBT_PASS', 'adminadmin')

conn_info = dict(
    host='127.0.0.1',
    port=qbt_port,
    username=qbt_user,
    password=qbt_pass
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
        logging.info(f"Concurrent file limit is ENABLED: {max_concurrent_files}")
    if only_video_files:
        logging.info(f"Video-only download mode is ENABLED.")
    
    # 动态识别当前用户选择的路线
    if rclone_cmd_template:
        logging.info(f"Route B (Single-file Instant Upload) is ENABLED. Command: {rclone_cmd_template}")
    else:
        logging.info("Route A (External Pulling) is ACTIVE. Awaiting external tools to move files.")

    state = load_state()

    while True:
        try:
            # ==== 步骤 0. 磁盘空间保护监控 ====
            if min_free_space_gb > 0:
                usage = shutil.disk_usage(DOWNLOAD_DIR)
                free_gb = usage.free / (1024 ** 3)
                
                if free_gb < min_free_space_gb:
                    logging.warning(f"[Disk Alert] Free space ({free_gb:.2f} GB) is below {min_free_space_gb} GB!")
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
                    logging.info(f"[Disk Safe] Free space is sufficient. Resuming previously paused torrents.")
                    qbt_client.torrents_resume(torrent_hashes=state['auto_paused_due_to_disk'])
                    state['auto_paused_due_to_disk'] = []
                    save_state(state)

            all_torrents = qbt_client.torrents_info()
            for torrent in all_torrents:
                
                # ==== 步骤 0.5 路线A核心：自动恢复外部拉取导致的报错 ====
                if auto_resume_missing and torrent.state in ['error', 'missingFiles']:
                    logging.info(f"[{torrent.name}] Detected state '{torrent.state}' (file moved). Auto-resuming to continue pipeline...")
                    qbt_client.torrents_resume(torrent_hashes=torrent.hash)
                    continue

                if torrent.progress >= 1.0:
                    continue
                if torrent.state == 'metaDL':
                    continue

                files = qbt_client.torrents_files(torrent_hash=torrent.hash)
                hash_key = torrent.hash
                
                # 初始化该种子的排队状态
                if hash_key not in state:
                    state[hash_key] = {}
                    for file in files:
                        file_id_str = str(file.index)
                        if file.priority != 0 and file.progress < 1.0:
                            state[hash_key][file_id_str] = 'pending'
                            qbt_client.torrents_file_priority(torrent_hash=hash_key, file_ids=[file.index], priority=0)
                            file.priority = 0
                        elif file.progress >= 1.0:
                            state[hash_key][file_id_str] = 'completed'
                        else:
                            state[hash_key][file_id_str] = 'ignored'

                # ==== 步骤1. 收尾处理与优先级干预 ====
                file_ids_to_ignore = []
                for file in files:
                    if file.progress >= 1.0 and file.priority != 0:
                        file_ids_to_ignore.append(file.index)
                if file_ids_to_ignore:
                    qbt_client.torrents_file_priority(torrent_hash=torrent.hash, file_ids=file_ids_to_ignore, priority=0)
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
                        qbt_client.torrents_file_priority(torrent_hash=torrent.hash, file_ids=non_video_ids, priority=0)

                # ==== 步骤1.8 路线B核心：单文件即时上传 ====
                if rclone_cmd_template:
                    for file in files:
                        file_id_str = str(file.index)
                        if file.progress >= 1.0 and state[hash_key].get(file_id_str) in ['downloading', 'pending']:
                            source_path = os.path.join(torrent.save_path, file.name)
                            
                            try:
                                cmd = rclone_cmd_template.format(
                                    source_path=source_path,
                                    torrent_name=torrent.name,
                                    file_name=os.path.basename(file.name),
                                    relative_path=file.name
                                )
                            except Exception as e:
                                logging.error(f"Error formatting RCLONE_CMD: {e}")
                                continue
                            
                            logging.info(f"[{torrent.name}] File 100% completed: {file.name}. Triggering instant upload...")
                            logging.info(f"Executing: {cmd}")
                            try:
                                subprocess.run(cmd, shell=True, check=True)
                                logging.info(f"[{torrent.name}] Upload SUCCESS: {os.path.basename(file.name)}")
                                state[hash_key][file_id_str] = 'uploaded'
                            except subprocess.CalledProcessError as e:
                                logging.error(f"[{torrent.name}] Upload FAILED: {e}")
                                state[hash_key][file_id_str] = 'upload_failed'
                            
                            save_state(state)

                # ==== 步骤2. 并发下载排队控制算法 ====
                if max_concurrent_files > 0:
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
