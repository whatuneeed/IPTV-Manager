'use strict';
'require view';
'require rpc';

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

function doStart(cb) {
    callExec({
        command: '/bin/sh',
        params: ['-c', CMD + ' start']
    }).then(function() {
        setTimeout(function() { cb(true); }, 8000);
    }).catch(function() {
        // Try fallback through CGI
        var x = new XMLHttpRequest();
        x.open('GET', FULL + '/cgi-bin/admin.cgi?action=server_start', true);
        x.timeout = 5000;
        x.onload = function() {
            setTimeout(function() { cb(true); }, 10000);
        };
        x.onerror = x.ontimeout = function() {
            setTimeout(function() { cb(false); }, 5000);
        };
        x.send();
    });
}

function doStop(cb) {
    callExec({
        command: '/bin/sh',
        params: ['-c', CMD + ' stop']
    }).then(function() {
        setTimeout(function() { cb(true); }, 5000);
    }).catch(function() {
        // Try fallback through CGI
        var x = new XMLHttpRequest();
        x.open('GET', FULL + '/cgi-bin/admin.cgi?action=server_stop', true);
        x.timeout = 5000;
        x.onload = function() {
            setTimeout(function() { cb(true); }, 5000);
        };
        x.onerror = x.ontimeout = function() {
            setTimeout(function() { cb(true); }, 5000);
        };
        x.send();
    });
}

return view.extend({
    load: function() { return Promise.resolve(); },

    render: function() {
        var box = E('div', {
            style: 'display:flex;flex-direction:column;align-items:center;gap:14px;padding:30px;background:var(--bg,#1a1b26);color:var(--text,#c0caf5);border-radius:8px;margin-top:10px'
        });

        var msg = E('div', {style:'font-size:15px;min-height:20px'}, 'Проверка...');
        var startBtn = E('button', {class:'cbi-button cbi-button-add', style:'padding:10px 24px;font-size:14px'}, 'Запустить сервер');
        var stopBtn = E('button', {class:'cbi-button cbi-button-negative', style:'padding:10px 24px;font-size:14px;display:none'}, 'Остановить сервер');

        var frame = E('iframe', {
            src: '', 
            style: 'width:100%;height:calc(100vh - 200px);border:none;display:none;border-radius:8px'
        });

        startBtn.onclick = function() {
            startBtn.disabled = true;
            startBtn.textContent = 'Запуск...';
            msg.textContent = 'Запуск сервера...';
            doStart(function(ok) {
                if (ok) {
                    msg.textContent = 'Успешно запущен!';
                    showFrame();
                } else {
                    msg.textContent = 'Ошибка запуска. Попробуйте ещё раз.';
                    startBtn.disabled = false;
                    startBtn.textContent = 'Запустить сервер';
                }
            });
        };

        stopBtn.onclick = function() {
            stopBtn.disabled = true;
            stopBtn.textContent = 'Остановка...';
            msg.textContent = 'Остановка сервера...';
            doStop(function(ok) {
                msg.textContent = 'Сервер остановлен';
                hideFrame();
            });
        };

        function showFrame() {
            box.style.display = 'none';
            frame.style.display = 'block';
            frame.src = FULL + '/server.html';
        }

        function hideFrame() {
            frame.style.display = 'none';
            box.style.display = 'flex';
            startBtn.style.display = '';
            startBtn.disabled = false;
            startBtn.textContent = 'Запустить сервер';
            stopBtn.style.display = 'none';
            stopBtn.disabled = false;
        }

        // Initial check
        isUp(function(running) {
            if (running) {
                showFrame();
            } else {
                msg.textContent = 'Сервер остановлен';
                box.appendChild(msg);
                box.appendChild(startBtn);
                box.appendChild(stopBtn);
            }
        });

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            box,
            frame
        ]);
    }
});
