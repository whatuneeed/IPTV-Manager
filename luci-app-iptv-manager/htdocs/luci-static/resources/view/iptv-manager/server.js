'use strict';
'require view';

var C = '/etc/iptv/IPTV-Manager.sh';
var LAN_IP = '192.168.1.1';
var PORT = '8082';

return view.extend({
    load: function() {
        return Promise.resolve();
    },

    render: function() {
        var self = this;
        var frame = E('iframe', {
            src: 'http://' + LAN_IP + ':' + PORT + '/server.html',
            style: 'width:100%;height:calc(100vh - 140px);border:none;background:#1a1b26'
        });

        var fallback = E('div', {
            style: 'display:none;padding:40px;text-align:center'
        }, [
            E('p', {style: 'color:#666;font-size:14px;margin-bottom:16px'}, 'Сервер остановлен'),
            E('button', {
                class: 'cbi-button cbi-button-add',
                style: 'padding:10px 24px;font-size:14px'
            }, 'Запустить')
        ]);

        fallback.querySelector('button').onclick = function() {
            this.disabled = true;
            this.textContent = 'Запуск...';
            fallback.querySelector('p').textContent = 'Запуск сервера...';

            // Try to start via ubus file.exec
            L.ubus.call('file', 'exec', {
                command: '/bin/sh',
                params: ['-c', C + ' start']
            }).then(function() {
                fallback.querySelector('p').textContent = 'Сервер запущен! Загрузка...';
                // Wait for server to come up
                self.waitForServer();
            }).catch(function() {
                fallback.querySelector('p').textContent = 'Ошибка запуска';
                self.disabled = false;
                self.textContent = 'Запустить';
            });
        };

        // Check if server is actually running - if not, show fallback
        this.checkServerRunning(function(running) {
            if (running) {
                frame.style.display = '';
                fallback.style.display = 'none';
            } else {
                frame.style.display = 'none';
                fallback.style.display = '';
            }
        });

        // Fallback: if iframe fails to load after 3s, show fallback UI
        var timer = setTimeout(function() {
            frame.style.display = 'none';
            fallback.style.display = '';
        }, 3000);

        // If iframe loads, cancel fallback
        frame.onload = function() {
            clearTimeout(timer);
            frame.style.display = '';
            fallback.style.display = 'none';
        };

        return E([
            E('h2', {}, 'Сервер'),
            E('p', {}, 'Управление IPTV сервером'),
            frame,
            fallback
        ]);
    },

    // Check if port 8082 responds
    checkServerRunning: function(cb) {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', 'http://' + LAN_IP + ':' + PORT + '/', true);
        xhr.timeout = 2000;
        xhr.onload = function() { cb(true); };
        xhr.onerror = function() { cb(false); };
        xhr.ontimeout = function() { cb(false); };
        xhr.send();
    },

    waitForServer: function() {
        var self = this;
        var attempts = 0;
        var check = function() {
            attempts++;
            self.checkServerRunning(function(running) {
                if (running) {
                    location.reload();
                } else if (attempts < 20) {
                    setTimeout(check, 1000);
                } else {
                    document.querySelector('p').textContent = 'Сервер не запустился. Попробуйте через терминал.';
                }
            });
        };
        // Start checking after 4s (server takes time to start)
        setTimeout(check, 4000);
    }
});
