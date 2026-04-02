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

        m = new form.Map('iptv', _('Расписание обновлений'),
            _('Автоматическое обновление плейлиста и EPG по расписанию'));

        s = m.section(form.TypedSection, 'main', null, true);
        s.anonymous = true;

        o = s.option(form.ListValue, 'playlist_interval', _('Интервал обновления плейлиста'));
        o.value('0', _('Выкл'));
        o.value('1', _('Каждый час'));
        o.value('6', _('Каждые 6 часов'));
        o.value('12', _('Каждые 12 часов'));
        o.value('24', _('Раз в сутки'));
        o.default = '0';

        o = s.option(form.ListValue, 'epg_interval', _('Интервал обновления EPG'));
        o.value('0', _('Выкл'));
        o.value('1', _('Каждый час'));
        o.value('6', _('Каждые 6 часов'));
        o.value('12', _('Каждые 12 часов'));
        o.value('24', _('Раз в сутки'));
        o.default = '0';

        return m.render();
    }
});
