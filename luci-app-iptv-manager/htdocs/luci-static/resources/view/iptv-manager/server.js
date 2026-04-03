'use strict';
'require view';
'require rpc';

var callExec = rpc.declare({
    object: 'file',
    method: 'exec',
    params: [ 'command', 'params' ],
    expect: { }
});

var C = '/etc/iptv/IPTV-Manager.sh';

function run(cmd) {
    return callExec({
        command: '/bin/sh',
        params: [ '-c', cmd ]
    });
}

return view.extend({
    load: function() {
        return Promise.resolve();
    },

    check: function(se) {
        return run(C + ' status').then(function(r) {
            var o = (r && r.stdout) ? String(r.stdout).trim() : '';
            var on = o.indexOf('running') > -1;
            se.el.textContent = on ? '● Запущен' : '○ Остановлен';
            se.el.style.color = on ? '#22c55e' : '#888';
            se.go.textContent = on ? '✓ Работает' : 'Запустить';
            se.go.disabled = false;
            se.off.disabled = on;
        }).catch(function(e) {
            se.el.textContent = '○ Остановлен';
            se.el.style.color = '#888';
            se.go.textContent = 'Запустить';
            se.go.disabled = false;
            se.off.disabled = true;
        });
    },

    render: function() {
        var se = {};
        var self = this;

        se.el = E('span', {style:'color:#888;font-size:14px;font-weight:600;min-width:140px'}, 'Проверка...');
        se.go = E('button', {class:'cbi-button cbi-button-add'}, 'Запустить');
        se.off = E('button', {class:'cbi-button cbi-button-negative'}, 'Остановить');

        se.go.onclick = function() {
            se.go.disabled = true;
            se.go.textContent = 'Запуск...';
            se.el.textContent = 'Запуск...';
            run(C + ' start').then(function() {
                return new Promise(function(ok) { setTimeout(ok, 6000); });
            }).then(function() {
                self.check(se);
            }).catch(function() {
                self.check(se);
            });
        };

        se.off.onclick = function() {
            se.off.disabled = true;
            se.off.textContent = 'Остановка...';
            se.el.textContent = 'Остановка...';
            run(C + ' stop').then(function() {
                return new Promise(function(ok) { setTimeout(ok, 3000); });
            }).then(function() {
                self.check(se);
            }).catch(function() {
                self.check(se);
            });
        };

        setTimeout(function() {
            self.check(se);
        }, 500);

        var row = E('div', {
            style: 'display:flex;gap:10px;flex-wrap:wrap;align-items:center'
        }, [se.go, se.off, se.el]);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', {style:'height:10px'}),
            E('div', {class:'cbi-section'}, [row])
        ]);
    }
});
