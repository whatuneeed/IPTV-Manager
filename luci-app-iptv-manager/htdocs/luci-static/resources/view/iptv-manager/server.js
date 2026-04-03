'use strict';
'require view';
'require ui';

var C = '/etc/iptv/IPTV-Manager.sh';
var P = '8082';
var F = 'http://192.168.1.1:' + P;

function isUp(cb) {
    var x = new XMLHttpRequest();
    x.open('GET', F + '/', true);
    x.timeout = 2000;
    x.onload = function() { cb(true); };
    x.onerror = x.ontimeout = function() { cb(false); };
    x.send();
}

function showFrame() {
    el.box.style.display = 'none';
    el.frame.style.display = 'block';
    el.frame.src = F + '/server.html';
}

function showBox(msg, showGo, showOff) {
    el.frame.style.display = 'none';
    el.box.style.display = '';
    el.msg.textContent = msg;
    el.go.style.display = showGo ? '' : 'none';
    el.off.style.display = showOff ? '' : 'none';
}

var el = {};

el.box = E('div', {
    style: 'padding:30px;text-align:center;background:var(--bg,#f0f2f5);color:var(--text,#1a1a2e);border-radius:8px;margin-top:10px'
});
el.msg = E('div', {style:'font-size:15px;margin-bottom:16px'}, 'Проверка...');
el.go = E('button', {class:'cbi-button cbi-button-add', style:'padding:10px 24px;font-size:14px'}, 'Запустить сервер');
el.off = E('button', {class:'cbi-button cbi-button-negative', style:'padding:10px 24px;font-size:14px'}, 'Остановить сервер');
el.frame = E('iframe', {
    src: '', style: 'width:100%;height:calc(100vh - 200px);border:none;display:none'
});

function run(cmd, cb) {
    L.ubus.call('file', 'exec', {
        command: '/bin/sh',
        params: ['-c', cmd]
    }).then(function(r) {
        cb(true);
    }).catch(function() {
        var x = new XMLHttpRequest();
        var act = cmd.indexOf('start') > -1 ? 'server_start' : cmd.indexOf('stop') > -1 ? 'server_stop' : 'server_status';
        x.open('GET', F + '/cgi-bin/admin.cgi?action=' + act, true);
        x.timeout = 15000;
        x.onload = function() { cb(true); };
        x.onerror = function() { cb(false); };
        x.ontimeout = function() { cb(false); };
        x.send();
    });
}

el.go.onclick = function() {
    el.go.disabled = true;
    el.go.textContent = 'Запуск...';
    el.msg.textContent = 'Запуск сервера...';
    run(C + ' start', function(ok) {
        if (ok) {
            el.msg.textContent = 'Запущен! Подождите...';
            setTimeout(function() { location.reload(); }, 8000);
        } else {
            el.msg.textContent = 'Ошибка запуска';
            showBox('Ошибка запуска', true, false);
            el.go.disabled = false;
            el.go.textContent = 'Запустить сервер';
        }
    });
};

el.off.onclick = function() {
    el.off.disabled = true;
    el.off.textContent = 'Остановка...';
    el.msg.textContent = 'Остановка сервера...';
    run(C + ' stop', function(ok) {
        if (ok) {
            el.msg.textContent = 'Сервер остановлен!';
            setTimeout(function() { location.reload(); }, 4000);
        } else {
            el.msg.textContent = 'Ошибка остановки';
            showBox('Ошибка остановки', false, true);
            el.off.disabled = false;
            el.off.textContent = 'Остановить сервер';
        }
    });
};

el.box.appendChild(el.msg);
el.box.appendChild(el.go);
el.box.appendChild(el.off);

// Initial check
isUp(function(running) {
    if (running) {
        el.frame.style.display = '';
        el.box.style.display = 'none';
        el.go.style.display = 'none';
        el.off.style.display = '';
        el.frame.src = F + '/server.html';
    } else {
        el.frame.style.display = 'none';
        el.go.style.display = '';
        el.off.style.display = 'none';
        el.msg.textContent = 'Сервер остановлен';
    }
});

return view.extend({
    load: function() { return Promise.resolve(); },

    render: function() {
        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            el.box,
            el.frame
        ]);
    }
});
