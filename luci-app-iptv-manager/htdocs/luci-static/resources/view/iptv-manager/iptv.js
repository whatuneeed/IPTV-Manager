'use strict';
'require view';
'require uci';
'require dom';

return view.extend({
    load: function() {
        return Promise.all([uci.load('iptv')]);
    },

    render: function() {
        var lan_ip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';
        var port = '8082';

        var frame = E('iframe', {
            'src': 'http://' + lan_ip + ':' + port + '/cgi-bin/admin.cgi',
            'style': 'width:100%;height:calc(100vh - 140px);border:none;',
            'frameborder': '0'
        });

        return E([
            E('h2', {}, _('IPTV')),
            E('p', {}, _('Управление каналами и просмотр ТВ')),
            frame
        ]);
    }
});
