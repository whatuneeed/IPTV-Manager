'use strict';
'require view';
'require uci';

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },
    render: function() {
        var lan_ip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';
        var frame = E('iframe', {
            'src': 'http://' + lan_ip + ':8082/server.html',
            'style': 'width:100%;height:calc(100vh - 140px);border:none;',
            'framebuffer': '0',
            'allowfullscreen': 'true',
            'allow': 'fullscreen'
        });
        return E([
            E('h2', {}, _('Сервер')),
            E('p', {}, _('Управление IPTV сервером')),
            frame
        ]);
    }
});
