'use strict';
'require view';
'require rpc';

var ex = rpc.declare({
    object: 'file',
    method: 'exec',
    params: ['cmd'],
    expect: {}
});

var C = '/etc/iptv/IPTV-Manager.sh';

return view.extend({
    load: function() { return Promise.resolve(); },

    ck: function(s) {
        ex({cmd: C + ' status'}).then(function(r) {
            var o = ((r && r.stdout) || '').trim();
            var ok = o.indexOf('running') > -1;
            s.st.textContent = ok ? '● Запущен' : '○ Остановлен';
            s.st.style.color = ok ? '#22c55e' : '#888';
            s.go.textContent = ok ? '✓ Работает' : 'Запустить';
            s.go.disabled = false;
            s.off.disabled = ok;
        }).catch(function() {
            s.st.textContent = '○ Остановлен';
            s.st.style.color = '#888';
            s.go.textContent = 'Запустить';
            s.go.disabled = false;
            s.off.disabled = true;
        });
    },

    render: function() {
        var s = {};
        s.self = this;
        s.st = E('span', {style:'color:#888;font-size:14px;font-weight:600'}, '...');
        s.go = E('button', {class:'cbi-button cbi-button-add'}, 'Запустить');
        s.off = E('button', {class:'cbi-button cbi-button-negative'}, 'Остановить');

        s.go.onclick = function() {
            s.go.disabled = true; s.go.textContent = 'Запуск...';
            s.st.textContent = 'Запуск...';
            ex({cmd: C + ' start'}).then(function() {
                return new Promise(function(r) { setTimeout(r, 6000); });
            }).then(function() { s.self.ck(s); }).catch(function() { s.self.ck(s); });
        };

        s.off.onclick = function() {
            s.off.disabled = true; s.off.textContent = 'Остановка...';
            s.st.textContent = 'Остановка...';
            ex({cmd: C + ' stop'}).then(function() {
                return new Promise(function(r) { setTimeout(r, 3000); });
            }).then(function() { s.self.ck(s); }).catch(function() { s.self.ck(s); });
        };

        var row = E('div', {style:'display:flex;gap:10px;flex-wrap:wrap;align-items:center'}, [s.go, s.off, s.st]);
        setTimeout(function() { s.self.ck(s); }, 500);

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            E('div', {style:'height:10px'}),
            E('div', {class:'cbi-section'}, [row])
        ]);
    }
});
