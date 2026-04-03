'use strict';
'require view';

return view.extend({
    load: function() { return Promise.resolve(); },
    render: function() {
        var frame = E('iframe', {
            'src': '/cgi-bin/srv.cgi',
            'style': 'width:100%;height:calc(100vh - 120px);border:none;',
            'frameborder': '0'
        });
        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            frame
        ]);
    }
});
