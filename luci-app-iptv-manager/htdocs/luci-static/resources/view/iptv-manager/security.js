'use strict';
'require view';
'require form';
'require uci';

return view.extend({
    load: function() {
        return Promise.all([uci.load('iptv')]);
    },

    render: function() {
        var m, s, o;

        m = new form.Map('iptv', _('Безопасность'),
            _('Пароль на админку и API токен для защиты IPTV Manager'));

        s = m.section(form.TypedSection, 'main', null, true);
        s.anonymous = true;

        o = s.option(form.Value, 'admin_user', _('Логин админки'));
        o.placeholder = _('Оставьте пустым для отключения');
        o.rmempty = true;

        o = s.option(form.Value, 'admin_pass', _('Пароль админки'));
        o.password = true;
        o.placeholder = _('Оставьте пустым для отключения');
        o.rmempty = true;

        o = s.option(form.Value, 'api_token', _('API токен'));
        o.placeholder = _('Оставьте пустым для отключения');
        o.rmempty = true;
        o.description = _('Передавайте в заголовке X-API-Token для доступа к API без пароля');

        return m.render();
    }
});
