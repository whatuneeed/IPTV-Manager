'use strict';
'require ui';

return view.extend({
    load: function() {
        return new Promise(function(resolve) {
            var x = new XMLHttpRequest();
            x.open('GET', '/cgi-bin/admin.cgi?action=server_status', true);
            x.timeout = 5000;
            x.onload = function() {
                try { var r = JSON.parse(x.responseText); resolve(r.output === 'running'); }
                catch(e) { resolve(false); }
            };
            x.onerror = function() { resolve(false); };
            x.ontimeout = function() { resolve(false); };
            x.send();
        });
    },

    render: function(isRunning) {
        var self = this;
        var statusEl = E('span', {
            style: 'color:' + (isRunning ? '#22c55e' : '#888') + ';font-weight:600;font-size:14px'
        }, isRunning ? '● Запущен' : '○ Остановлен');

        var btn = E('button', {
            class: 'cbi-button',
            style: 'padding:10px 28px;border-radius:6px;font-size:14px;font-weight:600;color:#fff;background:' + (isRunning ? '#ef4444' : '#22c55e') + ';border:none;cursor:pointer'
        }, isRunning ? '● Остановить' : '▶ Запустить');

        var card = E('div', {
            style: 'background:#fff;border-radius:8px;padding:20px;border:1px solid #e0e0e0;display:flex;gap:14px;align-items:center;flex-wrap:wrap;box-shadow:0 1px 3px rgba(0,0,0,.06)'
        });
        card.appendChild(btn);
        card.appendChild(statusEl);

        btn.onclick = function() {
            var action = isRunning ? 'server_stop' : 'server_start';
            btn.disabled = true;
            btn.style.opacity = '.6';
            btn.textContent = '⏳ Подождите...';
            statusEl.textContent = 'Выполняется...';
            statusEl.style.color = '#666';

            var x = new XMLHttpRequest();
            x.open('GET', '/cgi-bin/admin.cgi?action=' + action, true);
            x.timeout = 15000;
            x.onload = function() {
                statusEl.textContent = 'Подождите 6 сек...';
                setTimeout(function() { location.reload(); }, 6000);
            };
            x.onerror = function() {
                statusEl.textContent = 'Подождите 6 сек...';
                setTimeout(function() { location.reload(); }, 6000);
            };
            x.ontimeout = function() {
                statusEl.textContent = 'Подождите 6 сек...';
                setTimeout(function() { location.reload(); }, 6000);
            };
            x.send();
        };

        return E([
            E('h2', {}, '⚙️ Сервер'),
            E('p', {style:'color:#666;font-size:12px;margin-bottom:12px'}, 'Управление IPTV сервером — запуск и остановка'),
            card
        ]);
    }
});
