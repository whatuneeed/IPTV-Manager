'use strict';
'require view';
'require rpc';

var C = '/etc/iptv/IPTV-Manager.sh';

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command', 'params'],
    expect: {}
});

// If the iframe loads fine, it will override this page's content
// with the real server.html interface from port 8082.
// If the iframe fails (server stopped), it will show this fallback UI.
var frameHtml = '<!DOCTYPE html><html><head><style>body{margin:0;padding:0;font-family:-apple-system,sans-serif;background:#f0f2f5;color:#1a1a2e;display:flex;align-items:center;justify-content:center;min-height:100vh}.c{background:#fff;border-radius:12px;padding:32px;border:1px solid #e0e0e0;box-shadow:0 1px 3px rgba(0,0,0,.06);text-align:center;max-width:360px;width:90%}.b{padding:12px 24px;background:#1e8e3e;color:#fff;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer}.b:hover{background:#137333}.b:disabled{opacity:.5;cursor:default}.s{font-size:14px;color:#888;margin:16px 0}.l{font-size:11px;color:#888;margin-top:12px}</style></head><body><div class="c"><div class="s" id="s">Сервер остановлен</div><button class="b" id="go" onclick="parent.startServer()">Запустить</button><p class="l">Нажмите чтобы запустить IPTV Manager</p></div></body></html>';

return view.extend({
    load: function() {
        return callExec({
            command: '/bin/sh',
            params: ['-c', C + ' status']
        }).then(function(r) {
            var o = ((r && r.stdout) || '').trim();
            return o.indexOf('running') > -1;
        }).catch(function() {
            return false;
        });
    },

    render: function(isRunning) {
        var self = this;
        var lanIp = '192.168.1.1';
        var port = '8082';
        var frameSrc = 'http://' + lanIp + ':' + port + '/server.html';

        // Only show iframe if server IS running, otherwise show fallback
        var frameEl;
        var fallbackEl;

        fallbackEl = E('div', {style: 'padding:20px;text-align:center'}, [
            E('p', {style: 'color:#888;font-size:14px;margin-bottom:12px'}, isRunning ? 'Загрузка...' : 'Сервер остановлен'),
            E('button', {
                class: 'cbi-button cbi-button-add',
                style: 'padding:8px 20px;font-size:14px',
                click: function() {
                    this.disabled = true;
                    this.textContent = 'Запуск...';
                    fallbackEl.querySelector('p').textContent = 'Запуск сервера...';
                    callExec({
                        command: '/bin/sh',
                        params: ['-c', C + ' start']
                    }).then(function() {
                        fallbackEl.querySelector('p').textContent = 'Запущен! Перезагрузка...';
                        setTimeout(function() {
                            frameEl.style.display = '';
                            fallbackEl.style.display = 'none';
                            frameEl.src = frameSrc;
                        }, 8000);
                    }).catch(function() {
                        fallbackEl.querySelector('p').textContent = 'Ошибка запуска';
                        this.disabled = false;
                        this.textContent = 'Запустить';
                    });
                }
            }, 'Запустить')
        ]);

        frameEl = E('iframe', {
            src: isRunning ? frameSrc : '',
            style: 'width:100%;height:calc(100vh - 140px);border:none;' + (isRunning ? '' : 'display:none')
        });

        if (isRunning) {
            fallbackEl.style.display = 'none';
            frameEl.style.display = '';
        } else {
            fallbackEl.style.display = '';
            frameEl.style.display = 'none';
            fallbackEl.querySelector('p').textContent = 'Сервер остановлен';
            fallbackEl.querySelector('button').textContent = 'Запустить';
            fallbackEl.querySelector('button').disabled = false;
        }

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            fallbackEl,
            frameEl
        ]);
    }
});
