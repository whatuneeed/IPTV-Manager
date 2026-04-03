'use strict';
'require view';
'require rpc';

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['command', 'params'],
    expect: {}
});

var C = '/etc/iptv/IPTV-Manager.sh';

function run(cmd) {
    return callExec({
        command: '/bin/sh',
        params: ['-c', cmd]
    });
}

return view.extend({
    load: function() { return Promise.resolve(); },

    check: function(se) {
        return run(C + ' status').then(function(r) {
            var o = ((r && r.stdout) || '').trim();
            var on = o.indexOf('running') > -1;
            se.el.textContent = on ? '● Запущен' : '○ Остановлен';
            se.el.style.color = on ? '#22c55e' : '#888';
            se.el.style.fontWeight = '600';
            se.go.textContent = on ? '● Остановить' : '▶ Запустить';
            se.go.disabled = false;
            se.go.style.background = on ? '#ef4444' : '#22c55e';
        }).catch(function() {
            se.el.textContent = '○ Остановлен';
            se.el.style.color = '#888';
            se.el.style.fontWeight = '600';
            se.go.textContent = '▶ Запустить';
            se.go.style.background = '#22c55e';
            se.go.disabled = false;
        });
    },

    render: function() {
        var se = {};
        var self = this;

        se.el = E('span', {style:'color:#22c55e;font-weight:600;font-size:14px'}, 'Проверка...');

        se.go = E('button', {
            class: 'cbi-button',
            style: 'padding:10px 28px;border-radius:6px;font-size:14px;font-weight:600;color:#fff;background:#22c55e;border:none;cursor:pointer;transition:opacity .2s'
        }, '▶ Запустить');

        var card = E('div', {
            style: 'background:#fff;border-radius:8px;padding:20px;border:1px solid #e0e0e0;display:flex;gap:14px;align-items:center;flex-wrap:wrap;box-shadow:0 1px 3px rgba(0,0,0,.06)'
        });
        card.appendChild(se.go);
        card.appendChild(se.el);

        se.go.onclick = function() {
            se.go.disabled = true;
            se.go.textContent = '⏳ Запуск...';
            se.go.style.opacity = '.6';
            se.el.textContent = 'Запуск...';
            se.el.style.color = '#666';
            run(C + ' start').then(function() {
                se.el.textContent = 'Ждём 6 сек...';
                return new Promise(function(ok) { setTimeout(ok, 6000); });
            }).then(function() {
                self.check(se);
            }).catch(function() {
                se.el.textContent = 'Ошибка';
                se.el.style.color = '#ef4444';
                self.check(se);
            });
        };

        setTimeout(function() { self.check(se); }, 500);

        return E([
            E('h2', {}, '⚙️ Сервер'),
            E('p', {style:'color:#666;font-size:12px;margin-bottom:12px'}, 'Управление IPTV сервером — запуск и остановка'),
            card
        ]);
    }
});
