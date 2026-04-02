'use strict';
'require view';
'require uci';
'require rpc';

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command', 'params'],
    expect: {}
});

var IPTV_CMD = '/etc/iptv/IPTV-Manager.sh';

function doExec(cmd) {
    return callExec({
        command: '/bin/sh',
        params: ['-c', cmd]
    });
}

function checkStatus(sel) {
    doExec(IPTV_CMD + ' status').then(function(res) {
        var out = (res.stdout || '').trim();
        if (out.indexOf('running') > -1) {
            sel.statusEl.textContent = '● Запущен';
            sel.statusEl.style.color = '#22c55e';
            sel.startBtn.textContent = '✓ Работает';
            sel.startBtn.disabled = false;
            sel.stopBtn.disabled = false;
        } else {
            sel.statusEl.textContent = '○ Остановлен';
            sel.statusEl.style.color = '#666';
            sel.startBtn.textContent = 'Запустить';
            sel.startBtn.disabled = false;
            sel.stopBtn.disabled = true;
        }
    }).catch(function() {
        sel.statusEl.textContent = '○ Остановлен';
        sel.statusEl.style.color = '#666';
        sel.startBtn.textContent = 'Запустить';
        sel.startBtn.disabled = false;
        sel.stopBtn.disabled = true;
    });
}

return view.extend({
    load: function() {
        return L.resolveDefault(uci.load('iptv'), {});
    },

    render: function(data) {
        var sel = {};
        sel.statusEl = E('span', { 'style': 'color:#666;font-size:14px;font-weight:600' }, '...');

        sel.startBtn = E('button', {
            'class': 'cbi-button cbi-button-add',
            'click': function(ev) {
                sel.startBtn.disabled = true;
                sel.startBtn.textContent = 'Запуск...';
                sel.statusEl.textContent = 'Запуск...';
                doExec(IPTV_CMD + ' start').then(function() {
                    return new Promise(function(r) { setTimeout(r, 4000); });
                }).then(function() {
                    checkStatus(sel);
                }).catch(function() {
                    checkStatus(sel);
                });
            }
        }, 'Запустить');

        sel.stopBtn = E('button', {
            'class': 'cbi-button cbi-button-negative',
            'click': function(ev) {
                sel.stopBtn.disabled = true;
                sel.stopBtn.textContent = 'Остановка...';
                sel.statusEl.textContent = 'Остановка...';
                doExec(IPTV_CMD + ' stop').then(function() {
                    return new Promise(function(r) { setTimeout(r, 2000); });
                }).then(function() {
                    checkStatus(sel);
                }).catch(function() {
                    checkStatus(sel);
                });
            }
        }, 'Остановить');

        var btnRow = E('div', {
            'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [sel.startBtn, sel.stopBtn, sel.statusEl]);

        setTimeout(function() { checkStatus(sel); }, 500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', { 'style': 'height:10px' }),
            E('div', { 'class': 'cbi-section' }, [btnRow])
        ]);
    }
});
