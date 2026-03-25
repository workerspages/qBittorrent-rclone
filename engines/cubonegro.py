#VERSION: 0.11
# AUTHORS: camilobot

import json
from urllib.parse import urlencode

from novaprinter import prettyPrinter
from helpers import retrieve_url


class cubonegro(object):
    url = 'https://cubonegro.org'
    api_url = 'http://api.cubonegro.org'
    name = 'cubonegro'
    supported_categories = {'all': ''}

    # initialize trackers for magnet links
    trackers_list = [
        'udp://tracker.cubonegro.lol:6969/announce'
    ]
    trackers = '&'.join(urlencode({'tr': tracker}) for tracker in trackers_list)

    def search(self, what, cat='all'):
        search_url = "{}/api/dht/search/{}".format(self.api_url, what)
        desc_url = "{}/torrent/{}".format(self.url, what)

        data = []
        # get response json
        response = retrieve_url(search_url)
        data = json.loads(response)
        # parse results
        for row in data:
            res = {'link': self.download_link(row),
                   'name': row['title'],
                   'size': str(row['size']) + " B",
                   'seeds': -1,
                   'leech': -1,
                   'engine_url': self.url,
                   'desc_link': desc_url + row['hash']}
            prettyPrinter(res)

    def download_link(self, result):
        return "magnet:?xt=urn:btih:{}&{}&{}".format(
            result['hash'], urlencode({'dn': result['title']}), self.trackers)
