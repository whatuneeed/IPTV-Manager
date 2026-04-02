'use strict';
'require view';
'require uci';

return view.extend({
    load: function() {
        return Promise.all([uci.load('iptv')]);
    },

    render: function() {
        var lan_ip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';
        var port = '8082';

        var frame = E('iframe', {
            'src': 'http://' + lan_ip + ':' + port + '/player.html',
            'style': 'width:100%;height:calc(100vh - 140px);border:none;',
            'frameborder': '0'
        });

        return E([
            E('h2', {}, _('HLS Плеер')),
            E('p', {}, _('Просмотр IPTV каналов прямо в браузере')),
            frame
        ]);
    }
});
