'use strict';
'require view';
'require uci';

var IPTV = '/etc/iptv/IPTV-Manager.sh';

function execCmd(cmd) {
    return new Promise(function(resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/cgi-bin/luci/admin/status/services');
        xhr.setRequestHeader('Content-Type', 'application/json');
        var payload = JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'call',
            params: [
                window.__ubus_rpc_sid || [0, 0, 0, 0],
                'file',
                'exec',
                {command: '/bin/sh', params: ['-c', cmd]}
            ]
        });
        xhr.onload = function() {
            try {
                var data = JSON.parse(xhr.responseText);
                var result = data.result;
                if (result && result[1]) {
                    resolve(result[1]);
                } else if (data.error) {
                    reject(data.error);
                } else {
                    reject(new Error('empty result'));
                }
            } catch(e) { reject(e); }
        };
        xhr.onerror = function() { reject(new Error('network error')); };
        xhr.send(payload);
    });
}

function checkStatus(sel) {
    execCmd(IPTV + ' status').then(function(res) {
        var out = (res.stdout || '').trim();
        if (out.indexOf('running') > -1) {
            sel.statusEl.textContent = '\u25cf Запущен';
            sel.statusEl.style.color = '#22c55e';
            sel.startBtn.textContent = '\u2713 Работает';
            sel.startBtn.disabled = false;
            sel.stopBtn.disabled = false;
        } else {
            sel.statusEl.textContent = '\u25cb Остановлен';
            sel.statusEl.style.color = '#666';
            sel.startBtn.textContent = 'Запустить';
            sel.startBtn.disabled = false;
            sel.stopBtn.disabled = true;
        }
    }).catch(function() {
        sel.statusEl.textContent = '\u25cb Остановлен';
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
    render: function() {
        var sel = {};
        sel.statusEl = E('span', {style:'color:#666;font-size:14px;font-weight:600'},'...');
        sel.startBtn = E('button',{class:'cbi-button cbi-button-add',click:function(){
            sel.startBtn.disabled=true; sel.startBtn.textContent='Запуск...';
            sel.statusEl.textContent='Запуск...';
            execCmd(IPTV+' start').then(function(){
                return new Promise(function(r){setTimeout(r,4000)});
            }).then(function(){checkStatus(sel)}).catch(function(){checkStatus(sel)});
        }},'Запустить');
        sel.stopBtn = E('button',{class:'cbi-button cbi-button-negative',click:function(){
            sel.stopBtn.disabled=true; sel.stopBtn.textContent='Остановка...';
            sel.statusEl.textContent='Остановка...';
            execCmd(IPTV+' stop').then(function(){
                return new Promise(function(r){setTimeout(r,2000)});
            }).then(function(){checkStatus(sel)}).catch(function(){checkStatus(sel)});
        }},'Остановить');
        var btn = E('div',{style:'display:flex;gap:10px;flex-wrap:wrap;align-items:center'},
            [sel.startBtn,sel.stopBtn,sel.statusEl]);
        setTimeout(function(){checkStatus(sel)},500);
        return E([E('h2',{},'Сервер'),E('p',{},'Управление IPTV сервером'),
            E('div',{style:'height:10px'}),E('div',{class:'cbi-section'},[btn])]);
    }
});
