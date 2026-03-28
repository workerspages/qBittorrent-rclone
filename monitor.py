#!/usr/bin/env python3
import time
import os
import qbittorrentapi
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

qbt_port = int(os.environ.get('QBT_INTERNAL_PORT', 18080))
# 默认扫描频率为 60 秒
scan_interval = int(os.environ.get('MONITOR_INTERVAL', 60))

conn_info = dict(
    host='127.0.0.1',
    port=qbt_port,
)

qbt_client = qbittorrentapi.Client(**conn_info)

def monitor_torrents():
    # 循环尝试连接 qBittorrent API
    while True:
        try:
            # entrypoint 已经配置了 LocalHostAuth=false 免除本地回环鉴权
            qbt_client.auth_log_in()
            break
        except Exception as e:
            logging.warning(f"Waiting for qBittorrent WebUI to become available... ({e})")
            time.sleep(5)

    logging.info("Successfully connected to qBittorrent WebUI.")
    
    while True:
        try:
            all_torrents = qbt_client.torrents_info()
            for torrent in all_torrents:
                # 只处理尚未完全下载完成的合集种子
                if torrent.progress >= 1.0:
                    continue
                
                files = qbt_client.torrents_files(torrent_hash=torrent.hash)
                
                file_ids_to_ignore = []
                for file in files:
                    # 当该文件达到100%进度 (progress=1.0) 且它的下载优先级不是(不要下载0) 时
                    if file.progress >= 1.0 and file.priority != 0:
                        file_ids_to_ignore.append(file.index)
                
                if file_ids_to_ignore:
                    logging.info(f"Found {len(file_ids_to_ignore)} completed files in torrent: '{torrent.name}'. Setting priority to 'Do not download' (0).")
                    qbt_client.torrents_file_priority(
                        torrent_hash=torrent.hash,
                        file_ids=file_ids_to_ignore,
                        priority=0
                    )
        except Exception as e:
            logging.error(f"Error checking torrents: {e}")
            
        time.sleep(scan_interval)

if __name__ == '__main__':
    logging.info(f"Starting qBittorrent file monitor with a {scan_interval}s interval...")
    monitor_torrents()
