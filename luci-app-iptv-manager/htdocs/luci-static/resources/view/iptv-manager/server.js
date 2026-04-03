'use strict';
'require view';

return view.extend({
    load: function() { return Promise.resolve(); },

    render: function() {
        var status_el = E('span', { style: 'color:#64748b;font-size:14px' }, 'Загрузка...');

        var btn = E('button', {
            class: 'cbi-button cbi-button-action important',
            style: 'padding:8px 20px;border:none;border-radius:5px;cursor:pointer;font-size:13px;color:#fff;background:#22c55e'
        }, '▶ Запустить');

        var row = E('div', {
            class: 'cbi-section',
            style: 'display:flex;gap:14px;flex-wrap:wrap;align-items:center;padding:14px;border-radius:8px;margin-top:8px'
        }, [btn, status_el]);

        function check() {
            var x = new XMLHttpRequest();
            x.open('GET', '/cgi-bin/srv.cgi?action=status', true);
            x.timeout = 3000;
            x.onload = function() {
                try {
                    var r = JSON.parse(x.responseText);
                    if (r.ok && r.running) {
                        status_el.textContent = '● Запущен';
                        status_el.style.color = '#22c55e';
                        btn.textContent = '● Остановить';
                        btn.style.background = '#ef4444';
                    } else {
                        status_el.textContent = '○ Остановлен';
                        status_el.style.color = '#64748b';
                        btn.textContent = '▶ Запустить';
                        btn.style.background = '#22c55e';
                    }
                } catch(e) {
                    status_el.textContent = '○ Остановлен';
                    status_el.style.color = '#64748b';
                    btn.textContent = '▶ Запустить';
                    btn.style.background = '#22c55e';
                }
            };
            x.onerror = x.ontimeout = function() {
                status_el.textContent = '○ Остановлен';
                status_el.style.color = '#64748b';
                btn.textContent = '▶ Запустить';
                btn.style.background = '#22c55e';
            };
            x.send();
        }

        btn.onclick = function() {
            var action = btn.textContent.indexOf('Остановить') > -1 ? 'stop' : 'start';
            btn.disabled = true;
            btn.textContent = '⏳ ...';
            status_el.textContent = 'Выполняется...';
            status_el.style.color = '#64748b';

            var x = new XMLHttpRequest();
            x.open('GET', '/cgi-bin/srv.cgi?action=' + action, true);
            x.timeout = 15000;
            x.onload = function() {
                status_el.textContent = 'Подождите...';
                setTimeout(function() { location.reload(); }, 8000);
            };
            x.onerror = x.ontimeout = function() {
                status_el.textContent = 'Подождите...';
                setTimeout(function() { location.reload(); }, 8000);
            };
            x.send();
        };

        setTimeout(function() { check(); }, 500);

        return E([
            E('h2', {}, _('Сервер')),
            E('p', { style: 'color:#666;font-size:12px;margin-bottom:10px' }, _('Управление IPTV сервером')),
            row
        ]);
    }
});
