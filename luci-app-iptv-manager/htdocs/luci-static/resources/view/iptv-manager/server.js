'use strict';
'require view';
'require ui';
'require rpc';

var C = '/etc/iptv/IPTV-Manager.sh';

var r = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command', 'params'],
    expect: {}
});

function run(cmd) {
    return r({
        command: '/bin/sh',
        params: ['-c', cmd]
    });
}

function setStatus(se, on) {
    if (on) {
        se.el.textContent = '\u25cf Запущен';
        se.el.style.color = '#22c55e';
        se.go.textContent = '\u2713 Работает';
        se.go.disabled = false;
        se.off.disabled = false;
    } else {
        se.el.textContent = '\u25cb Остановлен';
        se.el.style.color = '#888';
        se.go.textContent = 'Запустить';
        se.go.disabled = false;
        se.off.disabled = true;
    }
}

return view.extend({
    load: function() {
        return run(C + ' status').then(function(r) {
            var o = (r && r.stdout) ? String(r.stdout).trim() : '';
            return o.indexOf('running') > -1;
        }).catch(function() {
            return false;
        });
    },

    render: function(isRunning) {
        var se = {};

        se.el = E('span', {
            style: 'color:' + (isRunning ? '#22c55e' : '#888') + ';font-size:14px;font-weight:600'
        }, isRunning ? '\u25cf Запущен' : '\u25cb Остановлен');

        se.go = E('button', {
            class: 'cbi-button cbi-button-add',
            disabled: isRunning
        }, isRunning ? '\u2713 Работает' : 'Запустить');

        se.off = E('button', {
            class: 'cbi-button cbi-button-negative',
            disabled: !isRunning
        }, 'Остановить');

        se.go.onclick = function() {
            se.go.disabled = true;
            se.go.textContent = 'Запуск...';
            se.el.textContent = 'Запуск...';
            run(C + ' start').then(function() {
                ui.addNotification(null, E('p', {}, 'Сервер запущен'), 'info');
                setStatus(se, true);
            }).catch(function() {
                se.go.disabled = false;
                se.go.textContent = 'Запустить';
                ui.addNotification(null, E('p', {}, 'Ошибка запуска'), 'error');
            });
        };

        se.off.onclick = function() {
            se.off.disabled = true;
            se.off.textContent = 'Остановка...';
            se.el.textContent = 'Остановка...';
            run(C + ' stop').then(function() {
                ui.addNotification(null, E('p', {}, 'Сервер остановлен'), 'info');
                setStatus(se, false);
            }).catch(function() {
                se.off.disabled = false;
                se.off.textContent = 'Остановить';
                ui.addNotification(null, E('p', {}, 'Ошибка остановки'), 'error');
            });
        };

        var row = E('div', {
            style: 'display:flex;gap:10px;flex-wrap:wrap;align-items:center;padding:10px'
        }, [se.go, se.off, se.el]);

        return E([
            E('h2', {}, '\u2699 Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', {class:'cbi-section'}, [row])
        ]);
    }
});
