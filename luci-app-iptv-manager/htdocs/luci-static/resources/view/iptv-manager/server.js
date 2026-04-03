'use strict';
'require view';
'require rpc';
'require ui';

var CMD = '/etc/iptv/IPTV-Manager.sh';
var PORT = '8082';
var LAN = '192.168.1.1';
var FULL = 'http://' + LAN + ':' + PORT;

function isUp(cb) {
    var x = new XMLHttpRequest();
    x.open('GET', FULL + '/', true);
    x.timeout = 2000;
    x.onload = function() { cb(true); };
    x.onerror = x.ontimeout = function() { cb(false); };
    x.send();
}

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command', 'params'],
    expect: {}
});

function doExec(cmd) {
    return callExec({
        command: '/bin/sh',
        params: ['-c', cmd]
    });
}

return view.extend({
    load: function() {
        return doExec(CMD + ' status').then(function(r) {
            var o = ((r && r.stdout) || '').trim();
            return o.indexOf('running') > -1;
        }).catch(function() {
            return false;
        });
    },

    render: function(isRunning) {
        var self = this;

        var box = E('div', {
            style: 'padding:30px;text-align:center;background:var(--bg,#f0f2f5);color:var(--text,#1a1a2e);border-radius:8px;margin-top:10px'
        });

        var msg = E('div', {style:'font-size:15px;min-height:20px;margin-bottom:16px'}, isRunning ? '' : 'Сервер остановлен');
        var goBtn = E('button', {class:'cbi-button cbi-button-add', style:'padding:10px 24px;font-size:14px'}, 'Запустить сервер');
        var offBtn = E('button', {class:'cbi-button cbi-button-negative', style:'padding:10px 24px;font-size:14px'}, 'Остановить сервер');

        goBtn.onclick = function() {
            goBtn.disabled = true;
            goBtn.textContent = 'Запуск...';
            msg.textContent = 'Запуск сервера...';
            doExec(CMD + ' start').then(function() {
                msg.textContent = 'Запущен! Загрузка...';
                setTimeout(function() { location.reload(); }, 8000);
            }).catch(function() {
                msg.textContent = 'Ошибка запуска';
                goBtn.disabled = false;
                goBtn.textContent = 'Запустить сервер';
            });
        };

        offBtn.onclick = function() {
            offBtn.disabled = true;
            offBtn.textContent = 'Остановка...';
            msg.textContent = 'Остановка сервера...';
            doExec(CMD + ' stop').then(function() {
                msg.textContent = 'Сервер остановлен!';
                setTimeout(function() { location.reload(); }, 4000);
            }).catch(function() {
                msg.textContent = 'Ошибка остановки';
                offBtn.disabled = false;
                offBtn.textContent = 'Остановить сервер';
            });
        };

        if (!isRunning) {
            box.appendChild(msg);
            box.appendChild(goBtn);
            box.appendChild(offBtn);
        }

        var frame = E('iframe', {
            src: isRunning ? FULL + '/server.html' : '',
            style: 'width:100%;height:calc(100vh - 200px);border:none;' + (isRunning ? '' : 'display:none')
        });

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            box,
            frame
        ]);
    }
});
