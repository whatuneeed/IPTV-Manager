'use strict';
'require view';
'require form';
'require uci';
'require ui';

return view.extend({
    load: function() {
        return Promise.all([
            uci.load('iptv')
        ]);
    },

    render: function() {
        var m, s, o;

        m = new form.Map('iptv', _('Настройки плейлиста'),
            _('Загрузка и управление IPTV плейлистом'));

        s = m.section(form.TypedSection, 'main', null, true);
        s.anonymous = true;

        o = s.option(form.Value, 'playlist_name', _('Название плейлиста'));
        o.placeholder = 'Мой плейлист';
        o.rmempty = true;

        o = s.option(form.ListValue, 'playlist_type', _('Тип плейлиста'));
        o.value('url', _('По ссылке (URL)'));
        o.value('file', _('Из файла'));
        o.value('provider', _('Провайдер'));
        o.value('', _('Не загружен'));

        o = s.option(form.Value, 'playlist_url', _('URL плейлиста'));
        o.placeholder = 'https://example.com/playlist.m3u';
        o.depends('playlist_type', 'url');

        o = s.option(form.Value, 'playlist_source', _('Путь к файлу'));
        o.placeholder = '/tmp/playlist.m3u';
        o.depends('playlist_type', 'file');

        o = s.option(form.Value, 'provider_name', _('Название провайдера'));
        o.depends('playlist_type', 'provider');

        o = s.option(form.Value, 'provider_login', _('Логин провайдера'));
        o.depends('playlist_type', 'provider');

        o = s.option(form.Value, 'provider_pass', _('Пароль провайдера'));
        o.password = true;
        o.depends('playlist_type', 'provider');

        o = s.option(form.Value, 'provider_server', _('Сервер провайдера'));
        o.placeholder = 'http://example.com';
        o.depends('playlist_type', 'provider');

        return m.render();
    }
});
